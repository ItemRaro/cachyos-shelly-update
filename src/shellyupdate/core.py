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
    ("repo", "Packages"),
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
SHOW_TRAY_WHEN_RELEVANT_PATTERN = re.compile(r"^\s*ShowTrayWhenRelevant\s*$")


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


def formatDuration(seconds: float) -> str | None:
    """cachy-update's format: "1d 2h 5m 3s", leaving out zero parts.
    None for zero (or negative) durations, which cachy-update doesn't show."""
    totalSeconds = int(seconds)
    if totalSeconds <= 0:
        return None
    parts = (("d", totalSeconds // 86400), ("h", totalSeconds % 86400 // 3600),
             ("m", totalSeconds % 3600 // 60), ("s", totalSeconds % 60))
    return " ".join(f"{value}{unit}" for unit, value in parts if value)


def readArchUpdateConfig() -> list[str]:
    """Lines of cachy-update's arch-update.conf: icon style and tray options
    are shared with it, so both look and behave the same."""
    try:
        return ARCH_UPDATE_CONFIG_FILE.read_text().splitlines()
    except OSError:
        return []


def showTrayWhenRelevant() -> bool:
    """cachy-update's ShowTrayWhenRelevant: hide the tray icon when up to date."""
    return any(SHOW_TRAY_WHEN_RELEVANT_PATTERN.match(line) for line in readArchUpdateConfig())


def currentTrayIcon(hasUpdates: bool) -> str:
    """cachy-update's icon names, honoring TrayIconStyle and ColorblindMode
    from arch-update.conf (the last TrayIconStyle line wins)."""
    iconStyle, colorblindSuffix = DEFAULT_ICON_STYLE, ""
    for line in readArchUpdateConfig():
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
