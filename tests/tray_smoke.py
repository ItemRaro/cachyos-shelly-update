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
for directory in ("run", "config", "bin"):
    (tempDir / directory).mkdir()
(tempDir / "config" / "kdeglobals").write_text(
    "[General]\nTerminalApplication=ghostty\n\n[Icons]\nTheme=Papirus-Dark\n")
# The KDE default terminal, plus another one that must not be picked
for terminalName in ("ghostty", "alacritty"):
    fakeTerminal = fakeBinDir / terminalName
    fakeTerminal.write_text(f'#!/bin/sh\necho "{terminalName} $*" >> "{terminalLog}"\n')
    fakeTerminal.chmod(0o755)

stateDir = tempDir / "state" / "cachyos-shelly-update"
stateDir.mkdir(parents=True)
(stateDir / "updates_repo").write_text("bar 2.0-1 -> 2.1-1\n")
(stateDir / "updates_aur").write_text("foo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\n")
(stateDir / "updates_appman").write_text("someapp 1.2.0 -> 1.3.0\n")
(stateDir / "updates_all").write_text(
    "bar 2.0-1 -> 2.1-1\nfoo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\nsomeapp 1.2.0 -> 1.3.0\n")
(stateDir / "last_check").write_text(f"{int(time.time()) - 600}\n")

sys.path.insert(0, str(REPO_ROOT / "src"))
from shellyupdate import tray  # noqa: E402

failures = []


def check(description, condition):
    print(("ok    " if condition else "FAIL  ") + description)
    if not condition:
        failures.append(description)


def menuTexts(trayApp):
    return [action.text() for action in trayApp.menu.actions()]


def subMenus(trayApp):
    return {action.text(): [item.text() for item in action.menu().actions()]
            for action in trayApp.menu.actions() if action.menu()}


check("kdeIconTheme reads kdeglobals", tray.kdeIconTheme() == "Papirus-Dark")

app = tray.QApplication(sys.argv)
tray.applyIconTheme()
check("applyIconTheme uses KDE's theme when Qt has none", tray.QIcon.themeName() == "Papirus-Dark")

trayApp = tray.TrayApp(app)
check("tooltip shows the total", "4 updates available" in trayApp.tray.toolTip())

trayApp.buildMenu()
texts, menus = menuTexts(trayApp), subMenus(trayApp)
print("      menu:", texts)
check("menu shows the total", "4 updates available" in texts)
check("Repositories (1) submenu", menus.get("Repositories (1)") == ["bar 2.0-1 -> 2.1-1"])
check("AUR (2) submenu", menus.get("AUR (2)") == ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"])
check("AppMan (1) submenu", menus.get("AppMan (1)") == ["someapp 1.2.0 -> 1.3.0"])
check("no submenu for an empty source", not any(text.startswith("Flatpak") for text in texts))
check("submenus in source order", [t for t in texts if "(" in t] == ["Repositories (1)", "AUR (2)", "AppMan (1)"])
check("last check", "Last check 10 min ago" in texts)
check("fixed actions", {"Run CachyOS-Shelly-Update", "Check for updates", "Quit"} <= set(texts))

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

# Long lists are cut off
(stateDir / "updates_aur").write_text("".join(f"pkg{i} 1 -> 2\n" for i in range(45)))
trayApp.buildMenu()
aurItems = subMenus(trayApp).get("AUR (45)", [])
check("submenu limited to 40 items plus a note", len(aurItems) == 41 and aurItems[-1] == "... and 5 more")

# Up to date
for fileName in ("updates_repo", "updates_aur", "updates_appman", "updates_all"):
    (stateDir / fileName).write_text("")
trayApp.refresh()
trayApp.buildMenu()
check("up to date: tooltip", "System is up to date" in trayApp.tray.toolTip())
check("up to date: menu", "System is up to date" in menuTexts(trayApp))

print()
if failures:
    print(f"{len(failures)} test(s) failed")
    sys.exit(1)
print("all tests passed")
