"""Tray icon for cachyos-shelly-update (in the style of cachy-update).

Reads the state written by `cachyos-shelly-update --check` and uses
cachy-update's icons. Needs PyQt6, which install.sh puts in a private
virtualenv; started by `cachyos-shelly-update --tray`.
"""

import configparser
import fcntl
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

from PyQt6.QtCore import QFileSystemWatcher, QTimer
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from . import core, terminal

MAX_ITEMS_PER_MENU = 40
DEFAULT_ICON_THEME = "breeze"
STATE_POLL_INTERVAL_MS = 60_000
STATE_DEBOUNCE_MS = 500
CHECK_POLL_INTERVAL_MS = 1000


def updaterBinary() -> str:
    return (os.environ.get("CACHYOS_SHELLY_UPDATE_BIN")
            or shutil.which(core.APP_NAME)
            or f"/opt/{core.APP_NAME}/bin/{core.APP_NAME}")


def timeUntilNextCheck() -> str | None:
    """When the systemd timer runs the next check, or None if unknown."""
    try:
        output = subprocess.run(
            ["systemctl", "--user", "show", f"{core.APP_NAME}.timer",
             "-p", "NextElapseUSecRealtime", "--value"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        if not output or output == "n/a":
            return None
        # Format: "Thu 2026-11-26 10:23:11 -03" -> drop the weekday and the zone
        fields = output.split()
        nextRun = datetime.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")
        return core.humanDuration((nextRun - datetime.now()).total_seconds())
    except Exception:
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


class TrayApp:
    def __init__(self, app: QApplication):
        self.app = app
        self.tray = QSystemTrayIcon()
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.buildMenu)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.onActivated)
        self.isChecking = False
        self.checkProcessTimer: QTimer | None = None

        core.STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Watch the state directory: the updater replaces the files with
        # rename, so watching the directory is more reliable than each file
        self.watcher = QFileSystemWatcher([str(core.STATE_DIR)])
        self.watcher.directoryChanged.connect(lambda _: self.scheduleRefresh())
        self.debounceTimer = QTimer(singleShot=True, interval=STATE_DEBOUNCE_MS)
        self.debounceTimer.timeout.connect(self.refresh)
        # Safety net in case a file system event is lost
        self.pollTimer = QTimer(interval=STATE_POLL_INTERVAL_MS)
        self.pollTimer.timeout.connect(self.refresh)
        self.pollTimer.start()

        self.refresh()
        self.tray.show()

    # ---------- state ----------
    def scheduleRefresh(self):
        self.debounceTimer.start()

    def iconName(self) -> str:
        names = core.readLines("tray_icon")
        return names[0].strip() if names else core.currentTrayIcon(False)

    def refresh(self):
        icon = QIcon.fromTheme(self.iconName())
        if icon.isNull():
            # Fallback when cachy-update's icons aren't installed
            hasUpdates = bool(core.readLines("updates_all"))
            icon = QIcon.fromTheme("update-high" if hasUpdates else "update-none",
                                   QIcon.fromTheme("system-software-update"))
        self.tray.setIcon(icon)

        updateCount = len(core.readLines("updates_all"))
        if self.isChecking:
            statusText = "Checking for updates..."
        elif updateCount == 0:
            statusText = "System is up to date"
        else:
            statusText = core.updatesAvailableText(updateCount)
        self.tray.setToolTip(f"{core.DISPLAY_NAME}\n{statusText}")

    # ---------- menu ----------
    def buildMenu(self):
        menu = self.menu
        menu.clear()
        updateCount = len(core.readLines("updates_all"))

        if self.isChecking:
            menu.addAction("Checking for updates...").setEnabled(False)
        elif updateCount == 0:
            menu.addAction(QIcon.fromTheme("checkmark"), "System is up to date").setEnabled(False)
        else:
            menu.addAction(QIcon.fromTheme("system-software-update"),
                           core.updatesAvailableText(updateCount)).triggered.connect(self.runUpdater)
            for sourceKey, sourceTitle in core.SOURCES:
                items = core.readLines(f"updates_{sourceKey}")
                if not items:
                    continue
                subMenu = menu.addMenu(f"{sourceTitle} ({len(items)})")
                for item in items[:MAX_ITEMS_PER_MENU]:
                    subMenu.addAction(item).setEnabled(False)
                if len(items) > MAX_ITEMS_PER_MENU:
                    subMenu.addAction(f"... and {len(items) - MAX_ITEMS_PER_MENU} more").setEnabled(False)

        menu.addSeparator()
        lastCheck = core.readLines("last_check")
        if lastCheck:
            try:
                elapsed = core.humanDuration(time.time() - int(lastCheck[0]))
                menu.addAction(f"Last check {elapsed} ago").setEnabled(False)
            except ValueError:
                pass
        nextCheck = timeUntilNextCheck()
        if nextCheck:
            menu.addAction(f"Next check in {nextCheck}").setEnabled(False)

        menu.addSeparator()
        menu.addAction(QIcon.fromTheme("system-run"), f"Run {core.DISPLAY_NAME}").triggered.connect(self.runUpdater)
        checkAction = menu.addAction(QIcon.fromTheme("view-refresh"), "Check for updates")
        checkAction.setEnabled(not self.isChecking)
        checkAction.triggered.connect(self.runCheck)
        menu.addAction(QIcon.fromTheme("application-exit"), "Quit").triggered.connect(self.app.quit)

    # ---------- actions ----------
    def onActivated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.runUpdater()

    def runUpdater(self):
        """Open the updater in the user's default terminal emulator."""
        command = terminal.terminalCommand([updaterBinary(), "--wait"], core.CONFIG_HOME)
        if command is None:
            self.tray.showMessage(core.DISPLAY_NAME,
                                  f"No terminal found. Set {terminal.OVERRIDE_VARIABLE}.")
            return
        subprocess.Popen(command, start_new_session=True)

    def runCheck(self):
        self.isChecking = True
        self.refresh()
        checkProcess = subprocess.Popen([updaterBinary(), "--check"], start_new_session=True,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Follow the process without blocking the UI
        processTimer = QTimer(interval=CHECK_POLL_INTERVAL_MS)

        def onTick():
            if checkProcess.poll() is not None:
                processTimer.stop()
                self.isChecking = False
                self.refresh()

        processTimer.timeout.connect(onTick)
        processTimer.start()
        self.checkProcessTimer = processTimer  # keep a reference so it isn't collected


def main():
    # Only one tray at a time; the lock lives as long as the process
    lockFile = open(core.RUN_DIR / f"{core.APP_NAME}-tray.lock", "w")
    try:
        fcntl.flock(lockFile, fcntl.LOCK_EX | fcntl.LOCK_NB)
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
