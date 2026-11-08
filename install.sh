#!/bin/bash
# GreekSoup: the one-person equity research desk. Installer for Mac and Linux.
#
# The careful way, which we recommend: download this file, read it, then run it.
#   curl -fsSL https://greeksoup.ai/install.sh -o install.sh
#   open -e install.sh        (Mac; on Linux open it in any text editor)
#   bash install.sh
# The quick way, the same file run straight from the site:
#   curl -fsSL https://greeksoup.ai/install.sh | bash
#
# What it does, in order. It prints this list first and waits 10 seconds, so you can stop it
# (close the window, or press Control-C) before anything changes. It asks you nothing, except your
# Mac password once if Python has to be installed.
#   1. Finds Python 3.10 or newer. On a Mac without it, it downloads python.org's installer,
#      checks the file is the exact one python.org published (its SHA-256 below) and that
#      Apple's notary vouches for the Python Software Foundation's signature, and only then
#      installs it, which asks for your password once. On Linux it tells you the package.
#   2. Downloads one named version of the desk (DESK_VERSION below) from GitHub, or from the
#      GitLab mirror when GitHub does not answer, and checks it before unpacking anything:
#      the release must be signed by the GreekSoup team's key (the same key the desk's own
#      updater checks every update against), and every file must match the signed list.
#      A download that fails the check is refused and nothing is installed.
#   3. Puts the desk in ~/GreekSoup and installs the Python packages it needs inside that
#      folder (.venv). Nothing else on the computer changes.
#   4. Sets the desk to start with your computer and restart itself if it stops (a LaunchAgent
#      on a Mac, a systemd user service on Linux). To skip that, run it as
#      GREEKSOUP_NO_SERVICE=1 bash install.sh   and it runs this time only. Either way you can
#      switch it on or off later on the desk's Settings screen.
#   5. Starts the desk and opens http://localhost:8765 in your browser.
# Run it again later and it only starts the desk; updates come through the strip inside
# the desk, checked against the same signature.
#
# Knobs (optional, put them before "bash"):
#   GREEKSOUP_HOME=/some/folder  GREEKSOUP_PORT=8770  GREEKSOUP_NO_SERVICE=1
#   GREEKSOUP_YES=1   skip the 10-second wait
set -e

# The desk's address on GitHub. A move of the repository changes this one line.
REPO="greeksoup/greeksoup-desk"
# The same repository, mirrored on GitLab with every push; used when GitHub does not answer.
MIRROR="shikshan-nivesh/greeksoup"
# The version this installer puts down. The desk offers anything newer through its own
# signed update strip, so a new install is never left behind.
DESK_VERSION="2026-11-07.145"
ZIP_URL="https://codeload.github.com/$REPO/zip/refs/tags/$DESK_VERSION"
MIRROR_ZIP_URL="https://gitlab.com/$MIRROR/-/archive/$DESK_VERSION/greeksoup-$DESK_VERSION.zip"
# python.org's Mac installer, pinned: the file's SHA-256 and the signer Apple must vouch for
PY_VERSION="3.12.7"
PY_PKG_URL="https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-macos11.pkg"
PY_PKG_SHA256="2ec2355c1b3225ce1075fc1b562a6e113017aa6177df87c410667638c1574a09"
PY_PKG_SIGNER="Developer ID Installer: Python Software Foundation (BMM5U3QVKW)"

DEST="${GREEKSOUP_HOME:-$HOME/GreekSoup}"
PORT="${GREEKSOUP_PORT:-8765}"
NO_SERVICE="${GREEKSOUP_NO_SERVICE:-}"
YES="${GREEKSOUP_YES:-}"
OS="$(uname -s)"

say()  { printf '\n  %s\n' "$*"; }
fail() { printf '\n  %s\n\n' "$*"; exit 1; }
# The 10-second wait is for a person reading the window; a test machine with no terminal skips it.
can_wait() { [ -z "$YES" ] && [ -t 1 ]; }

write_check() {   # the check below, written to a temporary file and run with the Python found above
  cat > "$TMP/check.py" <<'GREEKSOUP_CHECK'
# --- greeksoup release check: begin (the same lines in install.sh and install.ps1) ---
# Run as: python -I check.py <downloaded zip> <empty folder> <version>
# Unpacks the desk into the folder only when the GreekSoup team's key signed the release's
# MANIFEST.json, the manifest is the version this installer names, and every file in the zip is
# the exact bytes the signed manifest lists. Anything else: nothing is unpacked, exit code 3.
# The two keys are the ones the desk's own updater (updater.py) checks every update against.
import hashlib, json, os, sys, zipfile

KEYS = ("ad0b35bc58dee57f2d30e418678c6f9959490c7023568e2d7a2d0cb7af2883f5",
        "baf2906fae912e837f87f594ca407fc58a4e889ac3f49bb1cbf209248e534a91")
P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = pow(2, (P - 1) // 4, P)


def _x(y, sign):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P:
        x = x * I % P
    if (x * x - xx) % P or (x == 0 and sign):
        return None
    return P - x if (x & 1) != sign else x


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A, B = (y1 - x1) * (y2 - x2) % P, (y1 + x1) * (y2 + x2) % P
    C, E = t1 * 2 * D * t2 % P, z1 * 2 * z2 % P
    e, f, g, h = B - A, E - C, E + C, B + A
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(n, pt):
    q = (0, 1, 1, 0)
    while n:
        if n & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        n >>= 1
    return q


def _point(b):
    y = int.from_bytes(b, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= P:
        return None
    x = _x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


GY = 4 * pow(5, P - 2, P) % P
G = (_x(GY, 0), GY, 1, _x(GY, 0) * GY % P)


def ed25519_ok(key, msg, sig):
    if len(key) != 32 or len(sig) != 64:
        return False
    a, r = _point(key), _point(sig[:32])
    s = int.from_bytes(sig[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + key + msg).digest(), "little") % L
    lhs, rhs = _mul(s, G), _add(r, _mul(h, a))
    return (lhs[0] * rhs[2] - rhs[0] * lhs[2]) % P == 0 and (lhs[1] * rhs[2] - rhs[1] * lhs[2]) % P == 0


def _fold(b):
    return b.replace(b"\r\n", b"\n")


def _safe(rel):
    if not isinstance(rel, str) or not rel or "\\" in rel or rel.startswith("/") or ":" in rel:
        return False
    return all(part not in ("", ".", "..") for part in rel.split("/"))


def check_and_unpack(zip_path, out, version, keys=KEYS):
    """Returns the number of files unpacked; raises ValueError (nothing written) on any mismatch."""
    with zipfile.ZipFile(zip_path) as zf:
        names = [n for n in zf.namelist() if not n.endswith("/")]
        roots = {n.split("/", 1)[0] for n in names}
        if len(roots) != 1:
            raise ValueError("the download is not laid out like a GreekSoup release")
        root = roots.pop() + "/"
        have = set(names)
        try:
            raw = zf.read(root + "MANIFEST.json")
            sig = bytes.fromhex(zf.read(root + "MANIFEST.sig").decode("ascii").strip())
        except (KeyError, ValueError, UnicodeDecodeError):
            raise ValueError("the download carries no signature")
        if not any(ed25519_ok(bytes.fromhex(k), _fold(raw), sig) for k in keys):
            raise ValueError("the download is not signed by the GreekSoup team")
        manifest = json.loads(raw)
        if manifest.get("version") != version:
            raise ValueError("the download is version %s, not %s" % (manifest.get("version"), version))
        files = dict(manifest["files"])
        for rel in files:
            if not _safe(rel):
                raise ValueError("the release names a file outside the desk folder: " + rel[:80])
        blobs = {}
        for rel, want in sorted(files.items()):
            if root + rel not in have:
                raise ValueError(rel + " is missing from the download")
            data = zf.read(root + rel)
            if hashlib.sha256(_fold(data)).hexdigest() != want:
                raise ValueError(rel + " in the download is not the file the signed release lists")
            blobs[rel] = data
        blobs["MANIFEST.json"] = raw
        blobs["MANIFEST.sig"] = zf.read(root + "MANIFEST.sig")
    # every check passed; only now does anything touch the disk
    for rel, data in blobs.items():
        dst = os.path.join(out, *rel.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(data)
    return len(blobs)


if __name__ == "__main__":
    try:
        n = check_and_unpack(sys.argv[1], sys.argv[2], sys.argv[3])
    except (ValueError, OSError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print("  REFUSED: %s. Nothing was installed." % exc)
        sys.exit(3)
    print("  Signature checked: version %s, signed by the GreekSoup team, all %d files match." % (sys.argv[3], n))
# --- greeksoup release check: end ---
GREEKSOUP_CHECK
}

printf '\n  GreekSoup: the one-person equity research desk\n  ------------------------------------------------\n'

# ---------------------------------------------------------------- 1. Python
find_python() {
  for c in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$c" >/dev/null 2>&1; then
      if "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
        command -v "$c"; return 0
      fi
    fi
  done
  return 1
}
PY="$(find_python || true)"
if [ -z "$PY" ] && [ "$OS" != "Darwin" ]; then
  fail "Python 3.10 or newer is needed. On Ubuntu or Debian: sudo apt install python3 python3-venv   On Fedora: sudo dnf install python3   Then run this again."
fi

FRESH=""; [ -f "$DEST/server.py" ] || FRESH=1
SERVICE=""; [ -n "$NO_SERVICE" ] || SERVICE=1

# ---------------------------------------------------------------- 2. Say what will happen, then wait
if [ -n "$FRESH" ]; then
  printf '\n  This will:\n'
  if [ -n "$PY" ]; then
    printf '    - use the Python already here (%s)\n' "$("$PY" --version 2>&1)"
  else
    printf '    - install Python %s from python.org, after checking the file and its signature\n' "$PY_VERSION"
    printf '      (your Mac asks for your password once, for this step only)\n'
  fi
  printf '    - download GreekSoup %s and check it is signed by the GreekSoup team\n' "$DESK_VERSION"
  printf '      before anything is unpacked\n'
  printf '    - put it in %s, with the packages it needs inside that folder\n' "$DEST"
  if [ -n "$SERVICE" ]; then
    printf '    - start it with your computer and restart it if it stops\n'
    printf '      (to skip this: close this window and run   GREEKSOUP_NO_SERVICE=1 bash install.sh )\n'
  else
    printf '    - start it for this run only (GREEKSOUP_NO_SERVICE is set)\n'
  fi
  printf '    - open http://localhost:%s in your browser\n' "$PORT"
  if can_wait; then
    printf '\n  Starting in 10 seconds. To stop, close this window (or press Control-C).\n'
    sleep 10
  fi
fi

if [ -z "$PY" ]; then
  say "Downloading Python $PY_VERSION from python.org ..."
  PKG_DIR="$(mktemp -d)"
  PKG="$PKG_DIR/python-$PY_VERSION.pkg"
  curl -fsSL "$PY_PKG_URL" -o "$PKG" || fail "The Python download did not complete. Check the connection and run this again."
  GOT="$(shasum -a 256 "$PKG" | awk '{print $1}')"
  if [ "$GOT" != "$PY_PKG_SHA256" ]; then
    rm -rf "$PKG_DIR"
    fail "REFUSED: the Python installer is not the file python.org published (SHA-256 $GOT). Nothing was installed."
  fi
  SIG="$(pkgutil --check-signature "$PKG" 2>&1 || true)"
  if ! printf '%s' "$SIG" | grep -q "Status: signed by a developer certificate issued by Apple" ||
     ! printf '%s' "$SIG" | grep -qF "$PY_PKG_SIGNER"; then
    rm -rf "$PKG_DIR"
    fail "REFUSED: the Python installer's signature is not python.org's. Nothing was installed."
  fi
  say "Python installer checked: python.org's file, signed by the Python Software Foundation. Installing (your Mac asks for your password) ..."
  sudo installer -pkg "$PKG" -target / >/dev/null
  rm -rf "$PKG_DIR"
  PY="$(find_python || true)"
  [ -n "$PY" ] || fail "Python was installed but could not be found. Close this window, open a new Terminal and run this again."
fi
say "Python found: $("$PY" --version 2>&1)"

# ---------------------------------------------------------------- 3. The folder
if [ -z "$FRESH" ]; then
  say "The desk is already installed at $DEST. Starting it; new versions arrive through the strip inside the desk."
else
  [ ! -e "$DEST" ] || [ -z "$(ls -A "$DEST" 2>/dev/null)" ] || fail "$DEST already exists and is not a desk. Move it away, or pick another folder with GREEKSOUP_HOME=/some/folder."
  say "Downloading GreekSoup $DESK_VERSION ..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  write_check
  # GitHub first, then the GitLab mirror. Either copy has to pass the same check; one that
  # fails it is never unpacked, and the other source is tried.
  OK=""
  for url in "$ZIP_URL" "$MIRROR_ZIP_URL"; do
    rm -rf "$TMP/desk.zip" "$TMP/desk"; mkdir -p "$TMP/desk"
    curl -fsSL "$url" -o "$TMP/desk.zip" 2>/dev/null || continue
    if "$PY" -I "$TMP/check.py" "$TMP/desk.zip" "$TMP/desk" "$DESK_VERSION"; then OK=1; break; fi
  done
  [ -n "$OK" ] || fail "The desk was not installed: no download completed and passed the signature check. Check the connection and run this again; if it says REFUSED again, tell us at https://github.com/$REPO/issues"
  mkdir -p "$(dirname "$DEST")"
  rmdir "$DEST" 2>/dev/null || true
  mv "$TMP/desk" "$DEST"
fi
cd "$DEST"

# ---------------------------------------------------------------- 4. Its own environment
if [ ! -x ".venv/bin/python" ]; then
  say "Installing what the desk needs (into its own folder, nothing else on your computer changes) ..."
  "$PY" -m venv .venv
fi
.venv/bin/python -m pip install -q --upgrade pip >/dev/null 2>&1 || true
.venv/bin/python -m pip install -q -r requirements.txt

# ---------------------------------------------------------------- 5. Settings file
if [ ! -f ".env" ]; then
  cp .env.example .env
  if [ "$PORT" != "8765" ]; then
    sed -i.bak "s/^DESK_PORT=.*/DESK_PORT=$PORT/" .env && rm -f .env.bak
  fi
fi
chmod +x *.command *.sh 2>/dev/null || true
mkdir -p logs

# ---------------------------------------------------------------- 6. Start it, and keep it running unless skipped
already() { curl -s -m 2 -o /dev/null "http://localhost:$PORT/api/ping"; }
if already; then
  say "The desk is already running."
elif [ -z "$SERVICE" ]; then
  nohup .venv/bin/python server.py </dev/null >logs/desk.log 2>&1 &
  say "Started the desk (this run only; not set to start at login)."
elif [ "$OS" = "Darwin" ]; then
  DESK_PORT="$PORT" zsh "Keep Desk Running.command" </dev/null | sed 's/^/  /' | grep -v "close this window" || true
else
  UNIT_DIR="$HOME/.config/systemd/user"; mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/greeksoup-desk.service" <<UNIT
[Unit]
Description=GreekSoup desk
[Service]
ExecStart=$DEST/.venv/bin/python server.py
WorkingDirectory=$DEST
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload && systemctl --user enable --now greeksoup-desk.service
  say "The desk starts at every login and restarts by itself if it stops."
fi

for _ in $(seq 1 30); do already && break; sleep 2; done
already || fail "The desk has not answered yet. Give it a minute, then open http://localhost:$PORT . If it stays blank, read $DEST/logs/desk-service.log or give it to your AI agent."

# ---------------------------------------------------------------- 7. Open it
URL="http://localhost:$PORT"
if [ ! -t 1 ]; then :   # nobody reading the window (a test machine): no browser
elif [ "$OS" = "Darwin" ]; then open "$URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 || true; fi

if [ -z "$SERVICE" ]; then
  printf '\n  Done. The desk is at %s (this run only).\n' "$URL"
  printf '  To have it start with your computer later: Settings, "Start with the computer", inside the desk.\n'
else
  printf '\n  Done. The desk is at %s and it starts with your computer from now on.\n' "$URL"
  if [ "$OS" = "Darwin" ]; then printf '  To switch that off: double-click "Stop Desk" in the folder, or Settings inside the desk.\n'
  else printf '  To switch that off: systemctl --user disable --now greeksoup-desk.service\n'; fi
fi
printf '  Folder: %s\n' "$DEST"
printf '  Keys are optional: the Settings screen inside the desk takes them.\n'
printf '  Newer versions: the desk tells you on every screen and updates with one click.\n\n'
