"""The command line updater. Standard library only: the launcher runs it on
the project's virtualenv Python, or on the system python3 when the venv is
broken, so it must not need anything installed in the venv."""

import contextlib
import fcntl
import io
import os
import shutil
import subprocess
import sys
import time

from . import core, sources

USAGE = """\
cachyos-shelly-update - an arch-update/cachy-update style updater that uses
Shelly as the backend (repositories, AUR, Flatpak and AppImage) and also
updates the apps installed with AppMan.

Usage:
  cachyos-shelly-update             list the updates, ask, then apply them
  cachyos-shelly-update -c          background check (used by the timer):
                                    save the state, refresh the tray, notify
  cachyos-shelly-update -l          only list what can be updated
  cachyos-shelly-update -y          update without asking (uses Shelly's -n)
  cachyos-shelly-update --tray      start the tray icon
  cachyos-shelly-update --no-repo --no-aur --no-flatpak --no-appimage
                        --no-appman --no-devel
                                    skip specific sources
  cachyos-shelly-update -V          show the version
  cachyos-shelly-update -h          show this help

Optional config: ~/.config/cachyos-shelly-update/cachyos-shelly-update.conf
  (the same options as above, one per line, e.g. --no-devel)

Update/remove: /opt/cachyos-shelly-update/install.sh {update|uninstall}"""

if sys.stdout.isatty():
    BOLD, GREEN, YELLOW, RED, CYAN, RESET = "\033[1m", "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[0m"
else:
    BOLD = GREEN = YELLOW = RED = CYAN = RESET = ""


def printInfo(message: str) -> None:
    print(f"{GREEN}==>{RESET} {BOLD}{message}{RESET}")


def printWarning(message: str) -> None:
    print(f"{YELLOW}==> WARNING:{RESET} {message}")


def printError(message: str) -> None:
    print(f"{RED}==> ERROR:{RESET} {message}", file=sys.stderr)


def printTitle(message: str) -> None:
    print(f"\n{CYAN}{BOLD}:: {message}{RESET}")


class Options:
    def __init__(self) -> None:
        self.mode = "update"            # update | check | list | tray
        self.assumeYes = False
        self.skipDevel = False
        self.waitAtExit = False         # --wait: keep the terminal open at the end (used by the tray)
        self.enabledSources = set(core.SOURCE_KEYS)

    def apply(self, option: str, version: str) -> None:
        if option in ("-c", "--check"):
            self.mode = "check"
        elif option in ("-l", "--list"):
            self.mode = "list"
        elif option == "--tray":
            self.mode = "tray"
        elif option in ("-y", "--yes"):
            self.assumeYes = True
        elif option == "--no-devel":
            self.skipDevel = True
        elif option == "--wait":
            self.waitAtExit = True
        elif option == "--appman":
            self.enabledSources.add("appman")   # 1.0 compatibility: now the default
        elif option.startswith("--no-") and option[5:] in core.SOURCE_KEYS:
            self.enabledSources.discard(option[5:])
        elif option in ("-V", "--version"):
            print(f"{core.APP_NAME} {version}")
            sys.exit(0)
        elif option in ("-h", "--help"):
            print(USAGE)
            sys.exit(0)
        else:
            printError(f"Unknown option: {option}")
            sys.exit(1)


def parseOptions(arguments: list[str], version: str) -> Options:
    """The config file first, then the command line (so it can override it)."""
    options = Options()
    try:
        configLines = core.CONFIG_FILE.read_text().splitlines()
    except OSError:
        configLines = []
    for line in configLines:
        option = "".join(line.split("#", 1)[0].split())
        if option:
            options.apply(option, version)
    for argument in arguments:
        options.apply(argument, version)
    return options


def readVersion(prefix: str) -> str:
    try:
        with open(os.path.join(prefix, "VERSION")) as versionFile:
            return versionFile.read().strip() or "dev"
    except OSError:
        return "dev"


# How long an interactive run waits for a background check to finish
LOCK_WAIT_SECONDS = float(os.environ.get("CACHYOS_SHELLY_UPDATE_LOCK_TIMEOUT") or 300)
LOCK_RETRY_SECONDS = 0.5


def acquireLock(waitSeconds: float = 0) -> int | None:
    """The single-instance lock (our own, not pacman's): a descriptor that
    holds it until it is closed or we exit, or None if another run still
    holds it after waitSeconds. Python file descriptors aren't inherited by
    child processes, so a leftover child can never keep the lock after we exit."""
    lockDescriptor = core.openLockFile(core.LOCK_FILE)
    deadline = time.monotonic() + waitSeconds
    announced = False
    while True:
        try:
            fcntl.flock(lockDescriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lockDescriptor
        except OSError:
            if time.monotonic() >= deadline:
                os.close(lockDescriptor)
                return None
        if not announced:
            printInfo("Waiting for the background check to finish...")
            announced = True
        time.sleep(LOCK_RETRY_SECONDS)


def updateState(options: Options) -> None:
    """Check every enabled source and save the state files the tray reads."""
    results = sources.checkAll(options.enabledSources, options.skipDevel)
    allLines = []
    for key in core.SOURCE_KEYS:
        lines = results[key] if key in options.enabledSources else []
        core.writeStateFile(f"updates_{key}", "".join(f"{line}\n" for line in lines))
        allLines.extend(lines)
    core.writeStateFile("updates_all", "".join(f"{line}\n" for line in allLines))
    core.writeStateFile("last_check", f"{int(time.time())}\n")
    core.writeStateFile("tray_icon", core.currentTrayIcon(bool(allLines)) + "\n")


def markNotified() -> None:
    shutil.copyfile(core.stateFile("updates_all"), core.stateFile("notified"))


def notifyIfChanged() -> None:
    updateCount = core.countUpdates(["all"])
    allFile, notifiedFile = core.stateFile("updates_all"), core.stateFile("notified")
    try:
        alreadyNotified = notifiedFile.read_bytes() == allFile.read_bytes()
    except OSError:
        alreadyNotified = False
    if updateCount > 0 and not alreadyNotified and shutil.which("notify-send"):
        sources.runQuiet(["notify-send", "-a", core.DISPLAY_NAME, "-i", core.currentTrayIcon(True),
                          core.DISPLAY_NAME, core.updatesAvailableText(updateCount)])
    markNotified()


def showUpdateList(options: Options) -> None:
    for key, title in core.SOURCES:
        if key not in options.enabledSources:
            continue
        printTitle(title)
        lines = core.readLines(f"updates_{key}")
        print("\n".join(f"   {line}" for line in lines) if lines else "   no updates")
    print()


def showPostUpdateChecks() -> None:
    """Like arch-update: pending .pacnew files, orphans, replaced kernel."""
    if shutil.which("pacdiff"):
        pacnewFiles = sources.runQuiet(["pacdiff", "-o"]).strip()
        if pacnewFiles:
            printTitle("Pending .pacnew/.pacsave files")
            print("\n".join(f"   {line}" for line in pacnewFiles.splitlines()))
            print("   Review them with: sudo pacdiff -s")
    orphanPackages = sources.runQuiet(["pacman", "-Qtdq"]).strip()
    if orphanPackages:
        printTitle("Orphan packages")
        print("\n".join(f"   {line}" for line in orphanPackages.splitlines()))
        print("   Remove them with: sudo pacman -Rns $(pacman -Qtdq)")
    kernelRelease = os.uname().release
    if not os.path.isdir(f"/usr/lib/modules/{kernelRelease}"):
        printTitle("Reboot recommended")
        print(f"   The running kernel ({kernelRelease}) has been replaced.")


def startTray(selfPath: str, prefix: str, libDir: str) -> None:
    """Replace this process with the tray. The installer puts PyQt6 in a
    private virtualenv; fall back to this Python when running from the repository."""
    trayPython = os.path.join(prefix, ".venv", "bin", "python")
    if not os.access(trayPython, os.X_OK):
        trayPython = sys.executable
    environment = {**os.environ, "CACHYOS_SHELLY_UPDATE_BIN": selfPath, "PYTHONPATH": libDir}
    os.execve(trayPython, [trayPython, "-m", "shellyupdate.tray"], environment)


def main(selfPath: str, prefix: str, libDir: str, arguments: list[str]) -> int:
    if isinstance(sys.stdout, io.TextIOWrapper):
        sys.stdout.reconfigure(line_buffering=True)   # keep our lines in order with child output
    core.STATE_DIR.mkdir(parents=True, exist_ok=True)
    options = parseOptions(arguments, readVersion(prefix))

    def finish(exitCode: int) -> int:
        if options.waitAtExit:
            print()
            with contextlib.suppress(EOFError):
                input("Press Enter to close...")
        return exitCode

    if options.mode == "tray":
        startTray(selfPath, prefix, libDir)

    if not shutil.which("shelly"):
        printError("shelly not found (sudo pacman -S shelly)")
        return finish(1)

    if not shutil.which("flatpak"):
        options.enabledSources.discard("flatpak")    # also passes --no-flatpak to Shelly
    appmanBin = sources.findAppman()
    if "appman" in options.enabledSources and (appmanBin is None or sources.appmanAppsDir() is None):
        options.enabledSources.discard("appman")

    # The timer skips a round if another run is busy; an interactive run waits
    lock = acquireLock(0 if options.mode == "check" else LOCK_WAIT_SECONDS)
    if lock is None:
        if options.mode == "check":
            return 0
        printError(f"Another {core.APP_NAME} instance is already running.")
        return finish(1)

    # ---------- check mode (timer) ----------
    if options.mode == "check":
        updateState(options)
        notifyIfChanged()
        return 0

    # ---------- list / update modes ----------
    printInfo("Checking for updates...")
    updateState(options)
    markNotified()
    showUpdateList(options)

    shellyUpdateCount = core.countUpdates(core.SHELLY_SOURCE_KEYS)
    appmanUpdateCount = core.countUpdates(["appman"])
    totalUpdateCount = shellyUpdateCount + appmanUpdateCount
    if totalUpdateCount == 0:
        printInfo("System is up to date. Nothing to do.")
        return finish(0)
    printInfo(f"Available updates: {totalUpdateCount}")
    if options.mode == "list":
        return finish(0)

    if not options.assumeYes:
        try:
            answer = input(f"{CYAN}{BOLD}::{RESET} Proceed with the update? [Y/n] ").strip().lower()
        except EOFError:
            answer = "n"                # no terminal to answer: don't update
        if answer not in ("", "y", "yes"):
            printInfo("Cancelled.")
            return finish(0)

    # ---------- update ----------
    upgradeArgs = ["-n", "upgrade", "all"]    # -n: we already asked above
    upgradeArgs += [f"--no-{key}" for key in core.SHELLY_SOURCE_KEYS if key not in options.enabledSources]
    if options.skipDevel:
        upgradeArgs.append("--no-devel")

    exitStatus = 0
    if shellyUpdateCount > 0:
        printTitle("Updating with Shelly")
        if subprocess.run(["shelly", *upgradeArgs]).returncode != 0:
            exitStatus = 1
            printError("Shelly reported a failure in at least one backend.")
    if appmanUpdateCount > 0 and appmanBin:
        printTitle("Updating AppMan apps")
        if subprocess.run([appmanBin, "-u"]).returncode != 0:
            exitStatus = 1
            printError("appman -u failed.")

    if {"repo", "aur"} & options.enabledSources:
        showPostUpdateChecks()

    # Check again so the tray goes back to the "up to date" icon
    print()
    printInfo("Refreshing the tray state...")
    updateState(options)
    markNotified()

    print()
    if exitStatus == 0:
        printInfo("Update finished.")
    else:
        printWarning("Finished with errors. See the messages above.")
    return finish(exitStatus)
