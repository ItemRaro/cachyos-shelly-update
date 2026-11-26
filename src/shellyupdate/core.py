"""Shared by the CLI and the tray: paths, update sources, state files and texts.

Standard library only, and cheap to import: the timer runs the CLI often.
"""

import os
import re
from pathlib import Path

APP_NAME = "cachyos-shelly-update"
DISPLAY_NAME = "CachyOS-Shelly-Update"

HOME_DIR = Path.home()
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or HOME_DIR / ".local/state") / APP_NAME
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME") or HOME_DIR / ".config")
RUN_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
CONFIG_FILE = CONFIG_HOME / APP_NAME / f"{APP_NAME}.conf"
ARCH_UPDATE_CONFIG_FILE = CONFIG_HOME / "arch-update" / "arch-update.conf"
LOCK_FILE = RUN_DIR / f"{APP_NAME}.lock"

# (key, title) of every update source, in display order. The key names the
# state file (updates_<key>) and the --no-<key> option.
SOURCES = (
    ("repo", "Repositories"),
    ("aur", "AUR"),
    ("flatpak", "Flatpak"),
    ("appimage", "AppImage"),
    ("appman", "AppMan"),
)
SOURCE_KEYS = tuple(key for key, _ in SOURCES)
SHELLY_SOURCE_KEYS = ("repo", "aur", "flatpak", "appimage")

ICON_STYLES = ("blue", "light", "dark")
DEFAULT_ICON_STYLE = "blue"
TRAY_ICON_STYLE_PATTERN = re.compile(r"^\s*TrayIconStyle\s*=\s*(\S*)\s*$")
COLORBLIND_MODE_PATTERN = re.compile(r"^\s*ColorblindMode\s*$")


def stateFile(name: str) -> Path:
    return STATE_DIR / name


def readLines(name: str) -> list[str]:
    """Non-empty lines of a state file ([] if it doesn't exist)."""
    try:
        return [line for line in stateFile(name).read_text().splitlines() if line.strip()]
    except OSError:
        return []


def writeStateFile(name: str, content: str) -> None:
    """Replace a state file atomically, so the tray never reads half of one."""
    target = stateFile(name)
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_text(content)
    temporary.replace(target)


def countUpdates(keys) -> int:
    return sum(len(readLines(f"updates_{key}")) for key in keys)


def updatesAvailableText(count: int) -> str:
    return "1 update available" if count == 1 else f"{count} updates available"


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


def currentTrayIcon(hasUpdates: bool) -> str:
    """cachy-update's icon names, honoring TrayIconStyle and ColorblindMode
    from arch-update.conf (the last TrayIconStyle line wins)."""
    iconStyle, colorblindSuffix = DEFAULT_ICON_STYLE, ""
    try:
        configLines = ARCH_UPDATE_CONFIG_FILE.read_text().splitlines()
    except OSError:
        configLines = []
    for line in configLines:
        styleMatch = TRAY_ICON_STYLE_PATTERN.match(line)
        if styleMatch:
            iconStyle = styleMatch.group(1)
        elif COLORBLIND_MODE_PATTERN.match(line):
            colorblindSuffix = "-cb"
    if iconStyle not in ICON_STYLES:
        iconStyle = DEFAULT_ICON_STYLE
    if hasUpdates:
        return f"cachy-update_updates-available-{iconStyle}{colorblindSuffix}"
    return f"cachy-update-{iconStyle}"
