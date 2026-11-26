"""Tray icon for cachyos-shelly-update. Looks and behaves like cachy-update's
tray: the same icons and the same menu, except that each source shows just
its update count (no package lists).

Reads the state written by `cachyos-shelly-update --check`. Needs PyQt6,
which install.sh puts in a private virtualenv; started by
`cachyos-shelly-update --tray`.
"""

import configparser
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable

from PyQt6.QtCore import QFileSystemWatcher, QTimer
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from . import core, terminal

DEFAULT_ICON_THEME = "breeze"
STATE_POLL_INTERVAL_MS = 60_000
STATE_DEBOUNCE_MS = 500


def updaterBinary() -> str:
    return (os.environ.get("CACHYOS_SHELLY_UPDATE_BIN")
            or shutil.which(core.APP_NAME)
            or f"/opt/{core.APP_NAME}/bin/{core.APP_NAME}")


def timeUntilNextCheck() -> str | None:
    """When the systemd timer runs next, read the way cachy-update does it."""
    try:
        output = subprocess.run(
            ["systemctl", "--user", "list-timers", f"{core.APP_NAME}.timer", "-o", "json"],
            capture_output=True, text=True, timeout=3).stdout
        nextRunMicroseconds = json.loads(output)[0]["next"]
    except (OSError, subprocess.SubprocessError, ValueError, IndexError, KeyError, TypeError):
        return None
    if not nextRunMicroseconds:
        return None
    return core.formatDuration(nextRunMicroseconds / 1_000_000 - time.time())


def timeSinceLastCheck() -> str | None:
    lastCheck = core.readLines("last_check")
    try:
        return core.formatDuration(time.time() - int(lastCheck[0])) if lastCheck else None
    except ValueError:
        return None


def kdeIconTheme() -> str:
    """The icon theme set in KDE (kdeglobals [Icons] Theme), or Breeze."""
    config = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        config.read(core.CONFIG_HOME / "kdeglobals")
        return config.get("Icons", "Theme", fallback=DEFAULT_ICON_THEME) or DEFAULT_ICON_THEME
    except configparser.Error:
        return DEFAULT_ICON_THEME


def applyIconTheme() -> None:
    """PyQt6 from pip ships its own Qt, without KDE's platform theme plugin,
    so it doesn't know the desktop's icon theme. Use KDE's when Qt has none."""
    if QIcon.themeName() in ("", "hicolor"):
        QIcon.setThemeName(kdeIconTheme())


def sourceCounts() -> list[tuple[str, int]]:
    """(title, count) of every source with updates, in display order."""
    counts = ((title, len(core.readLines(f"updates_{key}"))) for key, title in core.SOURCES)
    return [(title, count) for title, count in counts if count]


class TrayApp:
    def __init__(self, app: QApplication) -> None:
        self.app = app
        self.tray = QSystemTrayIcon()
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.buildMenu)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.onActivated)

        core.STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Watch the state directory: the updater replaces the files with
        # rename, so watching the directory is more reliable than each file
        self.debounceTimer = QTimer()
        self.debounceTimer.setSingleShot(True)
        self.debounceTimer.setInterval(STATE_DEBOUNCE_MS)
        self.debounceTimer.timeout.connect(self.refresh)
        self.watcher = QFileSystemWatcher([str(core.STATE_DIR)])
        self.watcher.directoryChanged.connect(lambda _: self.debounceTimer.start())
        # Safety net in case a file system event is lost
        self.pollTimer = QTimer()
        self.pollTimer.setInterval(STATE_POLL_INTERVAL_MS)
        self.pollTimer.timeout.connect(self.refresh)
        self.pollTimer.start()

        self.refresh()

    # ---------- state ----------
    def iconName(self, updateCount: int) -> str:
        """The icon the updater picked; computed here too if it hasn't run yet."""
        names = core.readLines("tray_icon")
        return names[0].strip() if names else core.currentTrayIcon(bool(updateCount))

    def refresh(self) -> None:
        updateCount = len(core.readLines("updates_all"))
        icon: QIcon = QIcon.fromTheme(self.iconName(updateCount))
        if icon.isNull():
            # Fallback when cachy-update's icons aren't installed
            icon = QIcon.fromTheme("update-high" if updateCount else "update-none",
                                   QIcon.fromTheme("system-software-update"))
        self.tray.setIcon(icon)
        statusText = core.updatesAvailableText(updateCount) if updateCount else "System is up to date"
        self.tray.setToolTip(f"{core.DISPLAY_NAME}\n{statusText}")
        # cachy-update's ShowTrayWhenRelevant: only show the icon when there is something to do
        self.tray.setVisible(bool(updateCount) or not core.showTrayWhenRelevant())

    # ---------- menu ----------
    def addMenuItem(self, text: str, onTriggered: Callable[[], object] | None = None) -> None:
        """A menu entry; without a handler, a disabled label."""
        action = self.menu.addAction(text)
        if action is None:      # allowed by PyQt6's type stubs; Qt never does it
            return
        if onTriggered is None:
            action.setEnabled(False)
        else:
            action.triggered.connect(onTriggered)

    def buildMenu(self) -> None:
        """cachy-update's menu, rebuilt each time it opens."""
        self.menu.clear()
        updateCount = len(core.readLines("updates_all"))

        if updateCount:
            self.addMenuItem(core.updatesAvailableText(updateCount), self.runUpdater)
        else:
            self.addMenuItem("System is up to date")

        counts = sourceCounts()
        for title, count in counts:
            self.addMenuItem(f"{title} ({count})", self.runUpdater)
        if counts:
            self.menu.addSeparator()

        lastCheck = timeSinceLastCheck()
        if lastCheck:
            self.addMenuItem(f"Last check {lastCheck} ago")
        nextCheck = timeUntilNextCheck()
        if nextCheck:
            self.addMenuItem(f"Next check in {nextCheck}")

        self.menu.addSeparator()
        self.addMenuItem(f"Run {core.DISPLAY_NAME}", self.runUpdater)
        self.addMenuItem("Check for updates", self.runCheck)
        self.addMenuItem("Exit", self.app.quit)

    # ---------- actions ----------
    def onActivated(self, reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.runUpdater()

    def runUpdater(self) -> None:
        """Open the updater in the user's default terminal emulator."""
        command = terminal.terminalCommand([updaterBinary(), "--wait"], core.CONFIG_HOME)
        if command is None:
            self.tray.showMessage(core.DISPLAY_NAME,
                                  f"No terminal found. Set {terminal.OVERRIDE_VARIABLE}.")
            return
        subprocess.Popen(command, start_new_session=True)

    def runCheck(self) -> None:
        """Like cachy-update: start a check; the icon follows when the state changes."""
        subprocess.Popen([updaterBinary(), "--check"], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> None:
    # Only one tray at a time; the lock lives as long as the process
    lockDescriptor = core.openLockFile(core.RUN_DIR / f"{core.APP_NAME}-tray.lock")
    try:
        fcntl.flock(lockDescriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"The {core.APP_NAME} tray icon is already running.", file=sys.stderr)
        sys.exit(1)

    app = QApplication(sys.argv)
    app.setApplicationName(core.DISPLAY_NAME)
    app.setDesktopFileName(core.APP_NAME)
    app.setQuitOnLastWindowClosed(False)
    applyIconTheme()

    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("System tray not available.", file=sys.stderr)
        sys.exit(1)

    _trayApp = TrayApp(app)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
