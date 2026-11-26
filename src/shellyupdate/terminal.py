"""Find the user's default terminal emulator and build the command line that
runs a program in it. Standard library only, so it can be tested without Qt.

Linux has no single "default terminal" setting, so this follows the desktop:
  1. CACHYOS_SHELLY_UPDATE_TERMINAL, an explicit override for this app
  2. KDE Plasma: System Settings > Default Applications > Terminal emulator
     (TerminalApplication in kdeglobals)
  3. xdg-terminal-exec, the freedesktop default terminal launcher
     (GNOME 46+, Hyprland and others)
  4. $TERMINAL, the usual convention on tiling window managers
  5. x-terminal-emulator (Debian alternatives)
  6. the first installed terminal from a known list, Konsole first
"""

import configparser
import os
import shlex
import shutil
from pathlib import Path

OVERRIDE_VARIABLE = "CACHYOS_SHELLY_UPDATE_TERMINAL"

# How each terminal is told to run a command; anything else gets "-e"
EXECUTE_ARGUMENTS = {
    "kitty": [],
    "foot": [],
    "xdg-terminal-exec": [],
    "wezterm": ["start", "--"],
    "gnome-terminal": ["--"],
    "kgx": ["--"],
    "ptyxis": ["--"],
    "xfce4-terminal": ["-x"],
}
DEFAULT_EXECUTE_ARGUMENTS = ["-e"]

# Used only when nothing says which terminal is the default
FALLBACK_TERMINALS = (
    "konsole", "ghostty", "kitty", "alacritty", "foot", "wezterm",
    "ptyxis", "kgx", "gnome-terminal", "xfce4-terminal", "xterm",
)


def kdeTerminal(configHome: Path) -> list[str] | None:
    """The terminal picked in Plasma's settings, as an argument list."""
    if "KDE" not in os.environ.get("XDG_CURRENT_DESKTOP", "").upper().split(":"):
        return None
    config = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        config.read(configHome / "kdeglobals")
        value = config.get("General", "TerminalApplication", fallback="").strip()
        return shlex.split(value) or None
    except (configparser.Error, ValueError):
        return None


def withExecuteArguments(terminal: list[str], command: list[str]) -> list[str]:
    executableName = os.path.basename(terminal[0])
    return terminal + EXECUTE_ARGUMENTS.get(executableName, DEFAULT_EXECUTE_ARGUMENTS) + command


def defaultTerminal(configHome: Path) -> list[str] | None:
    """The user's default terminal as an argument list, or None if there is none."""
    candidates = []
    override = os.environ.get(OVERRIDE_VARIABLE, "").strip()
    if override:
        candidates.append(shlex.split(override))
    kdeChoice = kdeTerminal(configHome)
    if kdeChoice:
        candidates.append(kdeChoice)
    candidates.append(["xdg-terminal-exec"])
    terminalVariable = os.environ.get("TERMINAL", "").strip()
    if terminalVariable:
        candidates.append(shlex.split(terminalVariable))
    candidates.append(["x-terminal-emulator"])
    candidates.extend([name] for name in FALLBACK_TERMINALS)

    for candidate in candidates:
        if candidate and shutil.which(candidate[0]):
            return candidate
    return None


def terminalCommand(command: list[str], configHome: Path) -> list[str] | None:
    """The command line that opens `command` in the default terminal."""
    terminal = defaultTerminal(configHome)
    return withExecuteArguments(terminal, command) if terminal else None
