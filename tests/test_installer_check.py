"""The one-line installers check the release before they unpack it.

install.sh and install.ps1 each carry the same block of Python (the release check). These
tests hold the two copies identical, hold their keys to the updater's, and run the check
against releases signed by a throwaway test key: a good one unpacks, and a changed file, a
changed manifest, an unsigned zip, the wrong version or a path outside the folder is refused
with nothing written.
"""

import hashlib
import io
import json
import os
import re
import zipfile

import pytest

import updater

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEGIN = "# --- greeksoup release check: begin"
END = "# --- greeksoup release check: end ---"


def _block(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
        text = fh.read().replace("\r\n", "\n")
    i, j = text.index(BEGIN), text.index(END)
    return text[i:j + len(END)]


def _load():
    ns = {"__name__": "release_check"}
    exec(compile(_block("install.sh"), "release_check", "exec"), ns)
    return ns


def test_both_installers_carry_the_same_check():
    assert _block("install.sh") == _block("install.ps1")


def test_the_check_trusts_exactly_the_updaters_keys():
    assert tuple(_load()["KEYS"]) == tuple(updater.PUBLIC_KEYS)


def test_both_installers_pin_the_same_released_version_and_repo():
    sh = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
    ps = open(os.path.join(ROOT, "install.ps1"), encoding="utf-8").read()
    v_sh = re.search(r'^DESK_VERSION="([^"]+)"', sh, re.M).group(1)
    v_ps = re.search(r'^\$DeskVersion = "([^"]+)"', ps, re.M).group(1)
    assert v_sh == v_ps
    assert v_sh in [r["version"] for r in updater.local_releases()]
    repo_sh = re.search(r'^REPO="([^"]+)"', sh, re.M).group(1)
    repo_ps = re.search(r'^\$Repo = "([^"]+)"', ps, re.M).group(1)
    assert repo_sh == repo_ps == updater.REPO


def test_the_check_verifies_this_repositorys_own_signature():
    ns = _load()
    raw = open(os.path.join(ROOT, "MANIFEST.json"), "rb").read().replace(b"\r\n", b"\n")
    sig = bytes.fromhex(open(os.path.join(ROOT, "MANIFEST.sig"), encoding="ascii").read().strip())
    assert any(ns["ed25519_ok"](bytes.fromhex(k), raw, sig) for k in ns["KEYS"])
    assert not any(ns["ed25519_ok"](bytes.fromhex(k), raw + b" ", sig) for k in ns["KEYS"])


# ---------------------------------------------------------------- a throwaway signer, tests only
def _sign(ns, seed, msg):
    P, L, G, mul = ns["P"], ns["L"], ns["G"], ns["_mul"]

    def enc(pt):
        x, y, z, _ = pt
        zi = pow(z, P - 2, P)
        x, y = x * zi % P, y * zi % P
        return (y | ((x & 1) << 255)).to_bytes(32, "little")

    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    pub = enc(mul(a, G))
    r = int.from_bytes(hashlib.sha512(h[32:] + msg).digest(), "little") % L
    R = enc(mul(r, G))
    k = int.from_bytes(hashlib.sha512(R + pub + msg).digest(), "little") % L
    return pub, R + ((r + k * a) % L).to_bytes(32, "little")


SEED = b"greeksoup installer test key 32b"
FILES = {"server.py": b"print('desk')\n", "VERSION": b"2099-01-01.1  test\n", "web/a.html": b"<p>hi</p>\r\n"}


def _release(ns, tmp_path, version="2099-01-01.1", files=None, manifest_files=None, sign=True,
             tamper=None):
    files = dict(FILES if files is None else files)
    listed = manifest_files if manifest_files is not None else {
        rel: hashlib.sha256(b.replace(b"\r\n", b"\n")).hexdigest() for rel, b in files.items()}
    raw = json.dumps({"version": version, "files": listed}).encode()
    pub, sig = _sign(ns, SEED, raw)
    if tamper:
        files[tamper] = files[tamper] + b"\nimport os\n"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for rel, b in files.items():
            zf.writestr("greeksoup-x/" + rel, b)
        zf.writestr("greeksoup-x/MANIFEST.json", raw)
        if sign:
            zf.writestr("greeksoup-x/MANIFEST.sig", sig.hex())
    path = tmp_path / "desk.zip"
    path.write_bytes(buf.getvalue())
    return str(path), (pub.hex(),)


def test_a_signed_release_unpacks(tmp_path):
    ns = _load()
    z, keys = _release(ns, tmp_path)
    out = tmp_path / "out"
    out.mkdir()
    assert ns["check_and_unpack"](z, str(out), "2099-01-01.1", keys) == 5
    assert (out / "server.py").read_bytes() == FILES["server.py"]
    assert (out / "web" / "a.html").exists() and (out / "MANIFEST.sig").exists()


@pytest.mark.parametrize("case, kwargs, version, why", [
    ("changed file", {"tamper": "server.py"}, "2099-01-01.1", "not the file the signed release lists"),
    ("unsigned", {"sign": False}, "2099-01-01.1", "no signature"),
    ("older version", {}, "2098-01-01.1", "not 2098-01-01.1"),
    ("missing file", {"files": {"VERSION": FILES["VERSION"]},
                      "manifest_files": {"VERSION": hashlib.sha256(FILES["VERSION"]).hexdigest(),
                                         "server.py": "0" * 64}}, "2099-01-01.1", "missing"),
    ("outside the folder", {"files": {}, "manifest_files": {"../evil.py": "0" * 64}}, "2099-01-01.1", "outside"),
])
def test_a_bad_release_is_refused_and_nothing_is_written(tmp_path, case, kwargs, version, why):
    ns = _load()
    z, keys = _release(ns, tmp_path, **kwargs)
    out = tmp_path / "out"
    out.mkdir()
    with pytest.raises(ValueError, match=why):
        ns["check_and_unpack"](z, str(out), version, keys)
    assert list(out.iterdir()) == []


def test_a_release_signed_by_another_key_is_refused(tmp_path):
    ns = _load()
    z, _ = _release(ns, tmp_path)
    out = tmp_path / "out"
    out.mkdir()
    with pytest.raises(ValueError, match="not signed by the GreekSoup team"):
        ns["check_and_unpack"](z, str(out), "2099-01-01.1")    # the real keys, a test signature
    assert list(out.iterdir()) == []
