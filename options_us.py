"""US options positioning from the official public record of open interest. READ-ONLY.

The desk port of the options-tape method: take a daily snapshot of open
interest to disk, then read positioning from it: put/call by open interest,
the call and put walls, the biggest standing positions, and day-over-day
open-interest builds (fresh positioning) against the previous snapshot.

Source: OCC Series Search (marketdata.theocc.com/series-search), the options
clearing house's free per-underlying file. Keyless, tab-separated text, one
row per series: product symbol, expiry year/month/day, strike integer and
decimals, C/P, call open interest, put open interest, position limit. It
carries open interest only (no prices, volume or implied volatility), updated
once a day after the close, so the expected move, skew and volume-based
unusual strikes of the old CBOE reader are gone. CBOE closed its free delayed
chain files to automated readers on 20 Nov 2026; this replaced it.

Adjusted series (a root like 2AAPL after a corporate action) are left out:
their deliverable is not 100 plain shares. Twenty refusals in a row (a block,
an error page, the network) stop the sweep and pause the reader for six hours,
so a closed door is never hammered. Describe-only: no thesis call.
"""

import json
import os
import time
from datetime import datetime, timedelta

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
SNAP_DIR = os.path.join(HERE, "cache", "optsnap")
os.makedirs(SNAP_DIR, exist_ok=True)
PAUSE_FILE = os.path.join(SNAP_DIR, "_paused_until")

SOURCE = "https://marketdata.theocc.com/series-search"
UA = {"User-Agent": "GreekSoup-Desk (open-source research desk)"}

WINDOW_DAYS = 90        # expiries considered for positioning metrics
SNAP_KEEP_DAYS = 14     # pruned beyond this
BREAKER = 20            # refusals in a row that stop the sweep
PAUSE_HOURS = 6

REFUSED = "refused"     # the source did not answer (block, error page, network)


def _root(sym):
    """The symbol as the clearing house writes it: BRK.B -> BRKB."""
    return sym.upper().replace(".", "").replace("-", "").replace("/", "")


def parse_series(text, sym, today=None):
    """The Series Search text -> contracts in the window, or [] when none are listed."""
    today = today or datetime.now().date()
    horizon = today + timedelta(days=WINDOW_DAYS)
    root = _root(sym)
    out = []
    for line in (text or "").splitlines():
        f = [x.strip() for x in line.split("\t")]
        f = [x for x in f if x != ""]
        if len(f) < 10 or f[0] != root:
            continue                          # header lines and adjusted roots (2AAPL)
        try:
            exp = datetime(int(f[1]), int(f[2]), int(f[3])).date()
            strike = int(f[4]) + int(f[5]) / 1000
            cp = f[6]                         # "C P", "C" or "P": which sides are listed
            call_oi, put_oi = int(f[7]), int(f[8])
        except (ValueError, IndexError):
            continue
        if exp <= today or exp > horizon:
            continue                          # today's expiry is closing out, not positioning
        e = exp.strftime("%Y-%m-%d")
        if "C" in cp:
            out.append({"exp": e, "cp": "C", "strike": strike, "oi": call_oi})
        if "P" in cp:
            out.append({"exp": e, "cp": "P", "strike": strike, "oi": put_oi})
    return out


def fetch_chain(sym):
    """Open interest in the window: a list of contracts, None for no listed options, or REFUSED."""
    try:
        r = requests.get(SOURCE, params={"symbolType": "U", "symbol": _root(sym)}, headers=UA, timeout=20)
    except Exception:  # noqa: BLE001
        return REFUSED
    text = r.text or ""
    if r.status_code != 200 or "<html" in text[:500].lower():
        return REFUSED
    if "Series Search Results" not in text:
        return None                           # "Invalid symbol." / "No data exists": no listed options
    return parse_series(text, sym) or None


def _key(c):
    return f"{c['exp']}{c['cp']}{c['strike']:g}"


def save_snapshot(sym, contracts, day):
    """Persist today's OI per contract: tomorrow's build baseline."""
    try:
        with open(os.path.join(SNAP_DIR, f"{sym}_{day}.json"), "w") as fh:
            json.dump({_key(c): c["oi"] for c in contracts}, fh)
    except OSError:
        pass


def load_prev_snapshot(sym, day):
    """Most recent snapshot BEFORE `day` -> (date, {key: oi}), or (None, {})."""
    try:
        mine = sorted(f for f in os.listdir(SNAP_DIR)
                      if f.startswith(f"{sym}_") and f.endswith(".json")
                      and f[len(sym) + 1:-5] < day)
    except OSError:
        return None, {}
    if not mine:
        return None, {}
    f = mine[-1]
    try:
        with open(os.path.join(SNAP_DIR, f)) as fh:
            return f[len(sym) + 1:-5], json.load(fh)
    except (OSError, ValueError):
        return None, {}


def prune_snapshots():
    cutoff = (datetime.now() - timedelta(days=SNAP_KEEP_DAYS)).strftime("%Y-%m-%d")
    try:
        for f in os.listdir(SNAP_DIR):
            if f.endswith(".json") and f[:-5].rsplit("_", 1)[-1] < cutoff:
                os.remove(os.path.join(SNAP_DIR, f))
    except OSError:
        pass


def analyze(sym, contracts, prev_date, prev_oi, spot=None):
    calls = [c for c in contracts if c["cp"] == "C"]
    puts = [c for c in contracts if c["cp"] == "P"]
    call_oi, put_oi = sum(c["oi"] for c in calls), sum(c["oi"] for c in puts)

    # OI walls: the strikes where positioning is stacked (near-term window)
    def _wall(rows):
        agg = {}
        for c in rows:
            agg[c["strike"]] = agg.get(c["strike"], 0) + c["oi"]
        agg = {k: v for k, v in agg.items() if v > 0}
        if not agg:
            return None
        k = max(agg, key=agg.get)
        return {"strike": k, "oi": agg[k]}

    # the biggest standing positions: single contracts with the most open interest
    biggest = sorted((c for c in contracts if c["oi"] > 0), key=lambda c: -c["oi"])[:8]
    biggest = [{"exp": c["exp"], "cp": c["cp"], "strike": c["strike"], "oi": c["oi"]} for c in biggest]

    # day-over-day OI builds vs the previous snapshot
    builds = []
    if prev_oi:
        for c in contracts:
            d = c["oi"] - prev_oi.get(_key(c), 0)
            if d >= 250:
                builds.append({"exp": c["exp"], "cp": c["cp"], "strike": c["strike"],
                               "oi": c["oi"], "d_oi": d})
        builds.sort(key=lambda b: -b["d_oi"])

    return {
        "symbol": sym, "spot": spot,
        "pcr_oi": round(put_oi / call_oi, 2) if call_oi else None,
        "call_oi": call_oi, "put_oi": put_oi,
        "call_wall": _wall(calls), "put_wall": _wall(puts),
        "expiries": len({c["exp"] for c in contracts}),
        "biggest": biggest,
        "builds": builds[:8], "builds_vs": prev_date,
    }


def _paused():
    try:
        with open(PAUSE_FILE) as fh:
            return fh.read().strip() > datetime.now().strftime("%Y-%m-%d %H:%M")
    except OSError:
        return False


def _pause():
    try:
        with open(PAUSE_FILE, "w") as fh:
            fh.write((datetime.now() + timedelta(hours=PAUSE_HOURS)).strftime("%Y-%m-%d %H:%M"))
    except OSError:
        pass


def build(symbols, held, spot=None):
    """Snapshot + analyze every name; about a second between names keeps the source happy.
    `spot` is an optional symbol -> price lookup for the ladder; the figures stand without it."""
    day = datetime.now().strftime("%Y-%m-%d")
    out = {"names": [], "skipped": [], "window_days": WINDOW_DAYS,
           "ts": datetime.now().strftime("%Y-%m-%d %H:%M"), "stopped": False}
    if _paused():
        out["stopped"] = True
        return out
    prune_snapshots()
    refused = 0
    for sym in symbols:
        chain = fetch_chain(sym)
        if chain == REFUSED:
            refused += 1
            out["skipped"].append(sym)
            if refused >= BREAKER:
                _pause()
                out["stopped"] = True
                break
            time.sleep(1.0)
            continue
        refused = 0
        if chain is None:
            out["skipped"].append(sym)
            time.sleep(0.4)
            continue
        prev_date, prev_oi = load_prev_snapshot(sym, day)
        save_snapshot(sym, chain, day)
        px = None
        if spot:
            try:
                px = spot(sym)
            except Exception:  # noqa: BLE001
                px = None
        m = analyze(sym, chain, prev_date, prev_oi, px)
        m["held"] = sym in held
        out["names"].append(m)
        time.sleep(1.0)
    out["names"].sort(key=lambda n: (not n["held"], n["symbol"]))
    return out
