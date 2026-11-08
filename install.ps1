# GreekSoup: the one-person equity research desk. Installer for Windows.
#
# The careful way, which we recommend: download this file, read it, then run it.
#   irm https://greeksoup.ai/install.ps1 -OutFile install.ps1
#   notepad install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1
# The quick way, the same file run straight from the site:
#   irm https://greeksoup.ai/install.ps1 | iex
#
# What it does, in order. It prints this list and asks before it changes anything.
#   1. Finds Python 3.10 or newer, or installs Python 3.12 with winget (Microsoft's package
#      manager checks the installer's SHA-256 against its own catalogue before running it).
#   2. Downloads one named version of the desk ($DeskVersion below) from GitHub, or from the
#      GitLab mirror when GitHub does not answer, and checks it before unpacking anything:
#      the release must be signed by the GreekSoup team's key (the same key the desk's own
#      updater checks every update against), and every file must match the signed list.
#      A download that fails the check is refused and nothing is installed.
#   3. Puts the desk in %USERPROFILE%\GreekSoup and installs the Python packages it needs
#      inside that folder (.venv). Nothing else on the PC changes.
#   4. Asks whether the desk should start when you log on (a task for your user in Task
#      Scheduler, or a Startup shortcut; no administrator). Say no, or set
#      $env:GREEKSOUP_NO_SERVICE = "1" first, and it runs this time only.
#   5. Starts the desk and opens http://localhost:8765.
# A fresh Windows machine runs this whole file on every change to the desk; if a line
# still complains on yours, paste the window's text to your AI agent and ask it to fix it.
#
# Knobs (optional, set in the same window first):
#   $env:GREEKSOUP_HOME = "D:\Desk"   $env:GREEKSOUP_PORT = "8770"   $env:GREEKSOUP_NO_SERVICE = "1"
#   $env:GREEKSOUP_YES = "1"   no questions: go ahead, and start at logon
$ErrorActionPreference = "Stop"
# The desk's address on GitHub. A move of the repository changes this one line.
$Repo = "greeksoup/greeksoup-desk"
# The same repository, mirrored on GitLab with every push; used when GitHub does not answer.
$Mirror = "shikshan-nivesh/greeksoup"
# The version this installer puts down. The desk offers anything newer through its own
# signed update strip, so a new install is never left behind.
$DeskVersion = "2026-11-07.145"
$ZipUrls = @("https://codeload.github.com/$Repo/zip/refs/tags/$DeskVersion",
             "https://gitlab.com/$Mirror/-/archive/$DeskVersion/greeksoup-$DeskVersion.zip")
$Dest = if ($env:GREEKSOUP_HOME) { $env:GREEKSOUP_HOME } else { Join-Path $env:USERPROFILE "GreekSoup" }
$Port = if ($env:GREEKSOUP_PORT) { $env:GREEKSOUP_PORT } else { "8765" }
$NoService = -not [string]::IsNullOrWhiteSpace($env:GREEKSOUP_NO_SERVICE)
$Yes = -not [string]::IsNullOrWhiteSpace($env:GREEKSOUP_YES)

# The release check, run with the Python found below. Single-quoted, so PowerShell changes nothing in it.
$CheckPy = @'
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
'@

Write-Host "`n  GreekSoup: the one-person equity research desk`n  ------------------------------------------------"

# A question needs a person at the keyboard; a test machine, or GREEKSOUP_YES, takes the default.
function Can-Ask { return (-not $Yes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }
function Ask($Question, $Default) {
  $ans = ""
  if (Can-Ask) {
    $hint = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    try { $ans = Read-Host "`n  $Question $hint" } catch { $ans = "" }
  }
  if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
  return $ans.Trim().ToLower() -in @("y", "yes")
}

function Find-Python {
  foreach ($c in @("py -3.13", "py -3.12", "py -3.11", "py -3.10", "python3", "python")) {
    try {
      $v = & cmd /c "$c -c `"import sys;print(sys.version_info>=(3,10))`"" 2>$null
      if ($v -match "True") { return $c }
    } catch {}
  }
  return $null
}

# Download the named version, check it, and unpack it into $Out. GitHub first, then the mirror;
# either copy must pass the same check, and one that fails it is never unpacked.
function Get-CheckedDesk($Out) {
  $tmp = Join-Path $env:TEMP ("greeksoup-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $check = Join-Path $tmp "check.py"
    [IO.File]::WriteAllText($check, $CheckPy)
    $pyExe = (& cmd /c "$Py -c `"import sys;print(sys.executable)`"" | Select-Object -Last 1).Trim()
    foreach ($url in $ZipUrls) {
      $zip = Join-Path $tmp "desk.zip"
      Remove-Item -Force $zip -ErrorAction SilentlyContinue
      if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
      New-Item -ItemType Directory -Path $Out -Force | Out-Null
      try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing } catch { continue }
      & $pyExe -I $check $zip $Out $DeskVersion
      if ($LASTEXITCODE -eq 0) { return }
    }
    if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
    throw "The desk was not installed: no download completed and passed the signature check. Check the connection and run this again; if it says REFUSED again, tell us at https://github.com/$Repo/issues"
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

$Py = Find-Python
$Fresh = -not (Test-Path (Join-Path $Dest "server.py"))
$Service = -not $NoService

if ($Fresh) {
  Write-Host "`n  This will:"
  if ($Py) { Write-Host "    - use the Python already here ($Py)" }
  else { Write-Host "    - install Python 3.12 with winget (a window may ask you to approve)" }
  Write-Host "    - download GreekSoup $DeskVersion and check it is signed by the GreekSoup team"
  Write-Host "      before anything is unpacked"
  Write-Host "    - put it in $Dest, with the packages it needs inside that folder"
  if ($Service) { Write-Host "    - start it when you log on (you are asked next; no administrator needed)" }
  else { Write-Host "    - start it for this run only (GREEKSOUP_NO_SERVICE is set)" }
  Write-Host "    - open http://localhost:$Port in your browser"
  if ($Service) { $Service = Ask "Start the desk when you log on too? (no: it runs this time only)" "y" }
  if ((Can-Ask) -and -not (Ask "Go ahead?" "y")) { Write-Host "`n  Stopped. Nothing was changed.`n"; return }
}

if (-not $Py) {
  Write-Host "`n  Python is not on this PC yet. Installing it with winget (a window may ask you to approve)."
  winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements | Out-Null
  $Py = Find-Python
  if (-not $Py) { throw "Python was installed but could not be found. Close this window, open a new PowerShell and run this again." }
}
Write-Host "`n  Python found: $Py"

# Ask 127.0.0.1 rather than "localhost": on Windows "localhost" is often the IPv6
# address first, and the desk listens on the IPv4 one, so the name can say nothing is
# there while the desk is running perfectly well.
function Up { try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 2 -UseBasicParsing | Out-Null; $true } catch { $false } }

if (-not $Fresh) {
  if (Up) {
    Write-Host "`n  The desk is already installed at $Dest and running. New versions arrive through the strip inside the desk."
  } else {
    # Running the line again on an installed desk that is not up brings the folder to
    # the current version first (keys, lists and logs untouched), then starts it. A copy
    # too old to carry the updater gets the checked files of this version copied over it.
    Write-Host "`n  The desk is already installed at $Dest. Bringing it up to date, then starting it."
    if ((Test-Path (Join-Path $Dest "updater.py")) -and (Test-Path (Join-Path $Dest ".venv\Scripts\python.exe"))) {
      Push-Location $Dest
      try { & .venv\Scripts\python.exe updater.py apply 2>$null | Out-Null } catch {}
      Pop-Location
    } else {
      $Src = Join-Path $env:TEMP ("greeksoup-desk-" + [guid]::NewGuid().ToString())
      Get-CheckedDesk $Src
      Get-ChildItem -Path $Src -Force | Where-Object { $_.Name -notin @(".env", "data", "logs", "cache", ".venv") } |
        ForEach-Object { Copy-Item -Path $_.FullName -Destination $Dest -Recurse -Force }
      Remove-Item -Recurse -Force $Src
    }
  }
} else {
  if ((Test-Path $Dest) -and (Get-ChildItem -Path $Dest -Force | Select-Object -First 1)) {
    throw "$Dest already exists and is not a desk. Move it away, or pick another folder with `$env:GREEKSOUP_HOME."
  }
  Write-Host "`n  Downloading GreekSoup $DeskVersion ..."
  $Src = Join-Path $env:TEMP ("greeksoup-desk-" + [guid]::NewGuid().ToString())
  Get-CheckedDesk $Src
  New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
  if (Test-Path $Dest) { Remove-Item -Force $Dest }
  Move-Item -Path $Src -Destination $Dest
}
Set-Location $Dest

if (-not (Test-Path ".venv\Scripts\python.exe")) {
  Write-Host "`n  Installing what the desk needs (into its own folder) ..."
  & cmd /c "$Py -m venv .venv"
}
& .venv\Scripts\python.exe -m pip install -q --upgrade pip 2>$null
& .venv\Scripts\python.exe -m pip install -q -r requirements.txt

if (-not (Test-Path ".env")) {
  Copy-Item .env.example .env
  if ($Port -ne "8765") { (Get-Content .env) -replace "^DESK_PORT=.*", "DESK_PORT=$Port" | Set-Content .env }
}
New-Item -ItemType Directory -Path logs -Force | Out-Null

$Url = "http://localhost:$Port"
# Without start-at-logon (the reader said no, or GREEKSOUP_NO_SERVICE=1) the desk runs for
# this run only. GREEKSOUP_NO_SERVICE also skips opening a browser: it is how the desk is
# tested on a fresh Windows machine that nobody is sitting at.
$proc = $null
if (-not (Up)) {
  if (-not $Service) {
    $proc = Start-Process -FilePath (Join-Path $Dest ".venv\Scripts\python.exe") -ArgumentList "server.py" -WorkingDirectory $Dest `
      -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Dest "logs\desk.log") `
      -RedirectStandardError (Join-Path $Dest "logs\desk-start.log")
  } else {
    # Start at logon and start now, with no administrator needed: a task for this
    # user, or a Startup shortcut when Windows refuses the task. Run as its own
    # PowerShell so a PC that forbids scripts still runs this one.
    $env:DESK_PORT = $Port
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest "desk-autostart.ps1")
  }
}
for ($i = 0; $i -lt 30; $i++) { if (Up) { break }; Start-Sleep -Seconds 2 }
if (-not (Up)) {
  # Say what the desk itself printed, so the reader (or their agent) has the reason
  # in front of them instead of only the fact that nothing answered.
  Write-Host "`n  The desk has not answered yet. This is what it printed:"
  if ($proc) {
    if ($proc.HasExited) { Write-Host "  The desk stopped by itself, exit code $($proc.ExitCode)." }
    else { Write-Host "  The desk is still running as process $($proc.Id), but nothing answered on door $Port." }
  }
  foreach ($f in @("logs\desk.log", "logs\desk-start.log", "logs\desk-service.log")) {
    $p = Join-Path $Dest $f
    if (Test-Path $p) {
      $size = (Get-Item $p).Length
      Write-Host "`n  --- $f ($size bytes) ---"
      if ($size -gt 0) { Get-Content $p -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" } }
    } else {
      Write-Host "`n  --- ${f}: not there ---"
    }
  }
  throw "The desk has not answered yet. Give it a minute, then open $Url . If it stays blank, read $Dest\logs\desk.log or give it to your AI agent."
}
if (-not $NoService) { Start-Process $Url }
if ($Service) {
  Write-Host "`n  Done. The desk is at $Url and it starts when you log on from now on."
  Write-Host "  To switch that off: double-click Stop Desk in the folder, or Settings inside the desk."
} else {
  Write-Host "`n  Done. The desk is at $Url (this run only)."
  Write-Host "  To have it start when you log on later: Settings, Start with the computer, inside the desk."
}
Write-Host "  Folder: $Dest"
Write-Host "  Keys are optional: the Settings screen inside the desk takes them."
Write-Host "  Newer versions: the desk tells you on every screen and updates with one click.`n"
