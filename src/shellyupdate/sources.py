"""The update checks, one per source. Each returns the update lines to show.

Checks run in parallel (see checkAll): they mostly wait on the network.
Shelly calls stay in one sequence, since parallel runs of it are untested.
"""

import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .core import CONFIG_HOME, HOME_DIR

ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
SHELLY_NOISE_PATTERN = re.compile(
    r"^$|[Nn]o (updates|packages)|[Uu]p.to.date|[Nn]othing|^(::|==>|Checking|Fetching|Synchroniz)")
VERSION_NUMBER_PATTERN = re.compile(r"[0-9]+(\.[0-9]+)+")

APPMAN_CONFIG_FILE = CONFIG_HOME / "appman" / "appman-config"
# Seconds allowed for checking a single AppMan app (it queries upstream)
APPMAN_PROBE_TIMEOUT = float(os.environ.get("CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT") or 30)
APPMAN_PROBE_WORKERS = 8
# AM-updater lines that start the decision/download part: the probe stops there
APPMAN_PROBE_STOP_PATTERN = re.compile(r'^(\[ -n "\$version" \]|if )')
APPMAN_INSTALLED_VERSION_PATTERN = re.compile(r"^version0=")
# Also indented, or after ")" when set inside a "case $SITE" block
APPMAN_LATEST_VERSION_PATTERN = re.compile(r"(^|[ \t)])version=")


def runQuiet(command: list[str], extraEnvironment: dict | None = None) -> str:
    """stdout of a command, with stderr dropped and failures read as no output."""
    environment = {**os.environ, **extraEnvironment} if extraEnvironment else None
    try:
        return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              stdin=subprocess.DEVNULL, text=True, env=environment).stdout
    except OSError:
        return ""


def stripShellyNoise(output: str) -> list[str]:
    """Shelly's update lines without colors, blank lines and "nothing to do" messages."""
    lines = []
    for line in output.splitlines():
        line = ANSI_ESCAPE_PATTERN.sub("", line).lstrip()
        if not SHELLY_NOISE_PATTERN.search(line):
            lines.append(line)
    return lines


def shelly(*arguments: str) -> list[str]:
    return stripShellyNoise(runQuiet(["shelly", *arguments], {"LC_ALL": "C"}))


def checkRepo() -> list[str]:
    if shutil.which("checkupdates"):
        # Like arch-update: a temporary database, no root, the system one untouched
        with tempfile.TemporaryDirectory(prefix="cachyos-shelly-update-db.") as tempDb:
            output = runQuiet(["checkupdates"], {"CHECKUPDATES_DB": tempDb})
        return [line for line in output.splitlines() if line.strip()]
    return shelly("list-updates", "standard")


def checkAur(skipDevel: bool) -> list[str]:
    return shelly("list-updates", "aur", *(["--no-devel"] if skipDevel else []))


def checkAppimage() -> list[str]:
    return shelly("list-updates", "appimage")


def checkFlatpak() -> list[str]:
    if not shutil.which("flatpak"):
        return []
    runQuiet(["flatpak", "update", "--appstream"])
    output = runQuiet(["flatpak", "remote-ls", "--updates", "--columns=name,version"])
    return [re.sub(r"\t+", " ", line) for line in output.splitlines() if line.strip()]


# ---------- AppMan ----------
def findAppman() -> str | None:
    """AppMan installs itself in ~/.local/bin, which may not be in PATH."""
    candidate = shutil.which("appman")
    if candidate:
        return candidate
    binDir = Path(os.environ.get("XDG_BIN_HOME") or HOME_DIR / ".local/bin")
    candidate = binDir / "appman"
    return str(candidate) if os.access(candidate, os.X_OK) else None


def appmanAppsDir() -> Path | None:
    """Where AppMan keeps its apps (relative paths are relative to $HOME).
    No config file means AppMan was never set up: nothing to update."""
    try:
        appsDir = APPMAN_CONFIG_FILE.read_text().splitlines()[0].strip()
    except (OSError, IndexError):
        return None
    if not appsDir:
        return None
    appsPath = Path(appsDir) if appsDir.startswith("/") else HOME_DIR / appsDir
    return appsPath if appsPath.is_dir() else None


def buildAppmanProbe(updaterScript: str) -> str | None:
    """AppMan has no "check only" command: "appman -u" runs each app's
    AM-updater, which downloads right away. AM-updater scripts come from
    AppMan's templates and all start the same way: they set version0
    (installed) and version (upstream), and only then decide whether to
    download. The probe keeps just that first part and prints both values,
    so nothing is downloaded. None when the script doesn't follow the template."""
    probeLines, hasInstalled, hasLatest = [], False, False
    for line in updaterScript.splitlines():
        if APPMAN_PROBE_STOP_PATTERN.match(line):
            break
        hasInstalled = hasInstalled or bool(APPMAN_INSTALLED_VERSION_PATTERN.match(line))
        hasLatest = hasLatest or bool(APPMAN_LATEST_VERSION_PATTERN.search(line))
        probeLines.append(line)
    if not (hasInstalled and hasLatest):
        return None
    probeLines.append('printf "%s\\n%s\\n" "$version0" "$version"')
    return "\n".join(probeLines) + "\n"


def runAppmanProbe(probeScript: str, appDir: Path) -> tuple[str, str] | None:
    """(installed, latest) from a probe, or None if it failed or timed out.
    The probe gets its own process group so a timeout also kills whatever it
    was waiting on (a stuck curl), instead of leaving it running."""
    try:
        process = subprocess.Popen(["sh", "-c", probeScript], cwd=appDir, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                                   text=True, start_new_session=True)
    except OSError:
        return None
    try:
        output, _ = process.communicate(timeout=APPMAN_PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.communicate()
        return None
    if process.returncode != 0:
        return None
    lines = output.splitlines()
    return (lines[0], lines[1]) if len(lines) >= 2 else None


def shortVersion(version: str) -> str:
    """A version is often a download URL: show the number in its file name."""
    fileName = version.rsplit("/", 1)[-1].split("?", 1)[0]
    match = VERSION_NUMBER_PATTERN.search(fileName)
    return match.group(0) if match else (fileName or "?")


def checkAppmanApp(updaterFile: Path) -> str | None:
    try:
        probeScript = buildAppmanProbe(updaterFile.read_text(errors="replace"))
    except OSError:
        return None
    if probeScript is None:
        return None
    versions = runAppmanProbe(probeScript, updaterFile.parent)
    if versions is None:
        return None
    installedVersion, latestVersion = versions
    if not latestVersion or latestVersion == installedVersion:
        return None
    return f"{updaterFile.parent.name} {shortVersion(installedVersion)} -> {shortVersion(latestVersion)}"


def checkAppman() -> list[str]:
    appsDir = appmanAppsDir()
    if appsDir is None:
        return []
    updaterFiles = sorted(path for path in appsDir.glob("*/AM-updater") if path.is_file())
    if not updaterFiles:
        return []
    with ThreadPoolExecutor(max_workers=min(APPMAN_PROBE_WORKERS, len(updaterFiles))) as pool:
        results = pool.map(checkAppmanApp, updaterFiles)
    return [line for line in results if line]


# ---------- all sources ----------
def checkAll(enabledKeys: set[str], skipDevel: bool) -> dict[str, list[str]]:
    """Run every enabled check in parallel and return {source key: update lines}.
    Shelly is called from a single thread, one call after another; the repo
    check only joins that sequence when it has to fall back to Shelly."""
    results = {key: [] for key in ("repo", "aur", "flatpak", "appimage", "appman")}
    repoUsesShelly = shutil.which("checkupdates") is None

    def runShellyChecks():
        if "repo" in enabledKeys and repoUsesShelly:
            results["repo"] = checkRepo()
        if "aur" in enabledKeys:
            results["aur"] = checkAur(skipDevel)
        if "appimage" in enabledKeys:
            results["appimage"] = checkAppimage()

    def runIndependentCheck(key, check):
        if key in enabledKeys:
            results[key] = check()

    threads = [
        threading.Thread(target=runShellyChecks),
        threading.Thread(target=runIndependentCheck, args=("flatpak", checkFlatpak)),
        threading.Thread(target=runIndependentCheck, args=("appman", checkAppman)),
    ]
    if not repoUsesShelly:
        threads.append(threading.Thread(target=runIndependentCheck, args=("repo", checkRepo)))
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results
