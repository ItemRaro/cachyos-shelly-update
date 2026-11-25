#!/usr/bin/env python3
"""Tray icon for cachyos-shelly-update (in the style of cachy-update).

Reads the state written by `cachyos-shelly-update --check` in
~/.local/state/cachyos-shelly-update/ and uses cachy-update's icons.
Needs PyQt6, which install.sh puts in a private virtualenv.
"""

import configparser
import fcntl
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from PyQt6.QtCore import QFileSystemWatcher, QTimer
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

APP_NAME = "cachyos-shelly-update"
DISPLAY_NAME = "CachyOS-Shelly-Update"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / APP_NAME
RUN_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
# (state file suffix, menu title), in display order
SOURCES = [
    ("repo", "Repositories"),
    ("aur", "AUR"),
    ("flatpak", "Flatpak"),
    ("appimage", "AppImage"),
    ("appman", "AppMan"),
]
MAX_ITEMS_PER_MENU = 40
DEFAULT_ICON = "cachy-update-blue"
DEFAULT_ICON_THEME = "breeze"
STATE_POLL_INTERVAL_MS = 60_000
STATE_DEBOUNCE_MS = 500


def updaterBinary() -> str:
    return (os.environ.get("CACHYOS_SHELLY_UPDATE_BIN")
            or shutil.which(APP_NAME)
            or f"/opt/{APP_NAME}/bin/{APP_NAME}")


def readLines(fileName: str) -> list[str]:
    """Non-empty lines of a state file ([] if it doesn't exist)."""
    try:
        return [line for line in (STATE_DIR / fileName).read_text().splitlines() if line.strip()]
    except OSError:
        return []


def humanDuration(seconds: float) -> str:
    totalSeconds = int(abs(seconds))
    if totalSeconds < 60:
        return "less than 1 min"
    if totalSeconds < 3600:
        return f"{totalSeconds // 60} min"
    if totalSeconds < 86400:
        hours, minutes = divmod(totalSeconds // 60, 60)
        return f"{hours} h {minutes} min" if minutes else f"{hours} h"
    days, hours = divmod(totalSeconds // 3600, 24)
    return f"{days} d {hours} h" if hours else f"{days} d"


def updatesAvailableText(count: int) -> str:
    return "1 update available" if count == 1 else f"{count} updates available"


def timeUntilNextCheck() -> str | None:
    """When the systemd timer runs the next check, or None if unknown."""
    try:
        output = subprocess.run(
            ["systemctl", "--user", "show", f"{APP_NAME}.timer",
             "-p", "NextElapseUSecRealtime", "--value"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        if not output or output == "n/a":
            return None
        # Format: "Thu 2026-11-26 10:23:11 -03" -> drop the weekday and the zone
        fields = output.split()
        nextRun = datetime.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")
        return humanDuration((nextRun - datetime.now()).total_seconds())
    except Exception:
        return None


def terminalCommand(command: list[str]) -> list[str] | None:
    """Build the command that opens `command` in a terminal (Konsole first, KDE being the target)."""
    preferredTerminal = os.environ.get("CACHYOS_SHELLY_UPDATE_TERMINAL")
    terminals = [
        ("konsole", ["konsole", "-e"]),
        ("kitty", ["kitty"]),
        ("alacritty", ["alacritty", "-e"]),
        ("foot", ["foot"]),
        ("wezterm", ["wezterm", "start", "--"]),
        ("ghostty", ["ghostty", "-e"]),
        ("gnome-terminal", ["gnome-terminal", "--"]),
        ("xterm", ["xterm", "-e"]),
    ]
    if preferredTerminal:
        terminals.insert(0, (preferredTerminal, [preferredTerminal, "-e"]))
    for executable, prefix in terminals:
        if shutil.which(executable):
            return prefix + command
    return None


def kdeIconTheme() -> str:
    """The icon theme set in KDE (kdeglobals [Icons] Theme), or Breeze."""
    config = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        config.read(CONFIG_DIR / "kdeglobals")
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

        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Watch the state directory: cachyos-shelly-update replaces the files
        # with mv, so watching the directory is more reliable than each file
        self.watcher = QFileSystemWatcher([str(STATE_DIR)])
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
        names = readLines("tray_icon")
        return names[0].strip() if names else DEFAULT_ICON

    def refresh(self):
        icon = QIcon.fromTheme(self.iconName())
        if icon.isNull():
            # Fallback when cachy-update's icons aren't installed
            hasUpdates = bool(readLines("updates_all"))
            icon = QIcon.fromTheme("update-high" if hasUpdates else "update-none",
                                   QIcon.fromTheme("system-software-update"))
        self.tray.setIcon(icon)

        updateCount = len(readLines("updates_all"))
        if self.isChecking:
            statusText = "Checking for updates..."
        elif updateCount == 0:
            statusText = "System is up to date"
        else:
            statusText = updatesAvailableText(updateCount)
        self.tray.setToolTip(f"{DISPLAY_NAME}\n{statusText}")

    # ---------- menu ----------
    def buildMenu(self):
        menu = self.menu
        menu.clear()
        updateCount = len(readLines("updates_all"))

        if self.isChecking:
            menu.addAction("Checking for updates...").setEnabled(False)
        elif updateCount == 0:
            menu.addAction(QIcon.fromTheme("checkmark"), "System is up to date").setEnabled(False)
        else:
            menu.addAction(QIcon.fromTheme("system-software-update"),
                           updatesAvailableText(updateCount)).triggered.connect(self.runUpdater)
            for sourceKey, sourceTitle in SOURCES:
                items = readLines(f"updates_{sourceKey}")
                if not items:
                    continue
                subMenu = menu.addMenu(f"{sourceTitle} ({len(items)})")
                for item in items[:MAX_ITEMS_PER_MENU]:
                    subMenu.addAction(item).setEnabled(False)
                if len(items) > MAX_ITEMS_PER_MENU:
                    subMenu.addAction(f"... and {len(items) - MAX_ITEMS_PER_MENU} more").setEnabled(False)

        menu.addSeparator()
        lastCheck = readLines("last_check")
        if lastCheck:
            try:
                elapsed = humanDuration(time.time() - int(lastCheck[0]))
                menu.addAction(f"Last check {elapsed} ago").setEnabled(False)
            except ValueError:
                pass
        nextCheck = timeUntilNextCheck()
        if nextCheck:
            menu.addAction(f"Next check in {nextCheck}").setEnabled(False)

        menu.addSeparator()
        menu.addAction(QIcon.fromTheme("system-run"), f"Run {DISPLAY_NAME}").triggered.connect(self.runUpdater)
        checkAction = menu.addAction(QIcon.fromTheme("view-refresh"), "Check for updates")
        checkAction.setEnabled(not self.isChecking)
        checkAction.triggered.connect(self.runCheck)
        menu.addAction(QIcon.fromTheme("application-exit"), "Quit").triggered.connect(self.app.quit)

    # ---------- actions ----------
    def onActivated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.runUpdater()

    def runUpdater(self):
        command = terminalCommand([updaterBinary(), "--wait"])
        if command is None:
            self.tray.showMessage(DISPLAY_NAME, "No terminal found. Set CACHYOS_SHELLY_UPDATE_TERMINAL.")
            return
        subprocess.Popen(command, start_new_session=True)

    def runCheck(self):
        self.isChecking = True
        self.refresh()
        checkProcess = subprocess.Popen([updaterBinary(), "--check"], start_new_session=True,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Follow the process without blocking the UI
        processTimer = QTimer(interval=1000)

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
    lockFile = open(RUN_DIR / f"{APP_NAME}-tray.lock", "w")
    try:
        fcntl.flock(lockFile, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"The {APP_NAME} tray icon is already running.", file=sys.stderr)
        sys.exit(1)

    app = QApplication(sys.argv)
    app.setApplicationName(DISPLAY_NAME)
    app.setDesktopFileName(APP_NAME)
    app.setQuitOnLastWindowClosed(False)
    applyIconTheme()

    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("System tray not available.", file=sys.stderr)
        sys.exit(1)

    _trayApp = TrayApp(app)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
