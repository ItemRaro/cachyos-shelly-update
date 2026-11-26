"""Headless smoke test for the tray (QT_QPA_PLATFORM=offscreen).

Writes fake state files, builds the real tray and menu, checks what shows
up, and clicks "Run" to see which terminal it opens. Runs in CI and locally:
    pip install -r requirements.txt
    PYTHONPATH=src QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
"""

import os
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
tempDir = Path(tempfile.mkdtemp())
fakeBinDir = tempDir / "bin"
terminalLog = tempDir / "terminal.log"
os.environ.update({
    "XDG_STATE_HOME": str(tempDir / "state"),
    "XDG_RUNTIME_DIR": str(tempDir / "run"),
    "XDG_CONFIG_HOME": str(tempDir / "config"),
    "XDG_CURRENT_DESKTOP": "KDE",
    "PATH": f"{fakeBinDir}:{os.environ['PATH']}",
    "CACHYOS_SHELLY_UPDATE_BIN": "/opt/cachyos-shelly-update/bin/cachyos-shelly-update",
})
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
for directory in ("run", "config", "config/arch-update", "bin"):
    (tempDir / directory).mkdir()
(tempDir / "config" / "kdeglobals").write_text(
    "[General]\nTerminalApplication=ghostty\n\n[Icons]\nTheme=Papirus-Dark\n")
archUpdateConfig = tempDir / "config" / "arch-update" / "arch-update.conf"
# The KDE default terminal, plus another one that must not be picked
for terminalName in ("ghostty", "alacritty"):
    fakeTerminal = fakeBinDir / terminalName
    fakeTerminal.write_text(f'#!/bin/sh\necho "{terminalName} $*" >> "{terminalLog}"\n')
    fakeTerminal.chmod(0o755)
# systemctl list-timers -o json, as cachy-update reads it: next run in ~59 min
(fakeBinDir / "systemctl").write_text(
    f'#!/bin/sh\necho \'[{{"next": {int((time.time() + 3545) * 1_000_000)}}}]\'\n')
(fakeBinDir / "systemctl").chmod(0o755)

stateDir = tempDir / "state" / "cachyos-shelly-update"
stateDir.mkdir(parents=True)


def writeState(updatesBySource: dict[str, list[str]]):
    """What the updater writes after a check."""
    allLines = []
    for key in ("repo", "aur", "flatpak", "appimage", "appman"):
        lines = updatesBySource.get(key, [])
        (stateDir / f"updates_{key}").write_text("".join(f"{line}\n" for line in lines))
        allLines += lines
    (stateDir / "updates_all").write_text("".join(f"{line}\n" for line in allLines))
    (stateDir / "last_check").write_text(f"{int(time.time()) - 600}\n")
    (stateDir / "tray_icon").write_text(
        "cachy-update_updates-available-blue\n" if allLines else "cachy-update-blue\n")


writeState({"repo": ["bar 2.0-1 -> 2.1-1"], "aur": ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"],
            "appman": ["someapp 1.2.0 -> 1.3.0"]})

sys.path.insert(0, str(REPO_ROOT / "src"))
from shellyupdate import tray  # noqa: E402

failures = []


def check(description, condition):
    print(("ok    " if condition else "FAIL  ") + description)
    if not condition:
        failures.append(description)


def menuTexts(trayApp):
    return [action.text() for action in trayApp.menu.actions()]


check("kdeIconTheme reads kdeglobals", tray.kdeIconTheme() == "Papirus-Dark")

app = tray.QApplication(sys.argv)
tray.applyIconTheme()
check("applyIconTheme uses KDE's theme when Qt has none", tray.QIcon.themeName() == "Papirus-Dark")

trayApp = tray.TrayApp(app)
check("tooltip shows the total", "4 updates available" in trayApp.tray.toolTip())
check("icon: updates available", trayApp.iconName(4) == "cachy-update_updates-available-blue")
check("the tray is shown", trayApp.tray.isVisible())

trayApp.buildMenu()
texts = menuTexts(trayApp)
print("      menu:", texts)
check("menu starts with the total", texts[0] == "4 updates available")
check("one entry per source with updates, count only, in order",
      [t for t in texts if t.endswith(")")] == ["Packages (1)", "AUR (2)", "AppMan (1)"])
check("no submenus (no package lists)", not any(action.menu() for action in trayApp.menu.actions()))
check("no entry for sources without updates",
      not any(t.startswith(("Flatpak", "AppImage")) for t in texts))
check("last check in cachy-update's format", "Last check 10m ago" in texts)
check("next check from the systemd timer", any(t.startswith("Next check in 59m") for t in texts))
check("cachy-update's fixed actions, in order",
      texts[-3:] == ["Run CachyOS-Shelly-Update", "Check for updates", "Exit"])

# "Run" opens the updater in the desktop's default terminal (ghostty here,
# even though alacritty is installed too)
trayApp.runUpdater()
for _ in range(50):
    if terminalLog.exists():
        break
    time.sleep(0.1)
launched = terminalLog.read_text().strip() if terminalLog.exists() else ""
print("      launched:", launched)
check("Run opens the KDE default terminal with the updater",
      launched == "ghostty -e /opt/cachyos-shelly-update/bin/cachyos-shelly-update --wait")

# Up to date: the icon, tooltip and menu follow the new state
writeState({})
trayApp.refresh()
trayApp.buildMenu()
texts = menuTexts(trayApp)
check("up to date: icon changes back", trayApp.iconName(0) == "cachy-update-blue")
check("up to date: tooltip", "System is up to date" in trayApp.tray.toolTip())
check("up to date: menu", texts[0] == "System is up to date")
check("up to date: no source entries", not any(t.endswith(")") for t in texts))

# cachy-update's ShowTrayWhenRelevant: hidden while up to date
archUpdateConfig.write_text("ShowTrayWhenRelevant\n")
trayApp.refresh()
check("ShowTrayWhenRelevant hides the icon when up to date", not trayApp.tray.isVisible())
writeState({"flatpak": ["App 1.0"]})
trayApp.refresh()
check("ShowTrayWhenRelevant shows it again when there are updates", trayApp.tray.isVisible())

print()
if failures:
    print(f"{len(failures)} test(s) failed")
    sys.exit(1)
print("all tests passed")
