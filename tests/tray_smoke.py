"""Headless smoke test for the tray (QT_QPA_PLATFORM=offscreen).

Writes fake state files, builds the real tray and menu, and checks what
shows up. Runs in CI and locally:
    QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
"""

import os
import runpy
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
tempDir = Path(tempfile.mkdtemp())
os.environ["XDG_STATE_HOME"] = str(tempDir / "state")
os.environ["XDG_RUNTIME_DIR"] = str(tempDir / "run")
os.environ["XDG_CONFIG_HOME"] = str(tempDir / "config")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
(tempDir / "run").mkdir()
(tempDir / "config").mkdir()
(tempDir / "config" / "kdeglobals").write_text("[General]\nColorScheme=BreezeDark\n\n[Icons]\nTheme=Papirus-Dark\n")

stateDir = tempDir / "state" / "cachyos-shelly-update"
stateDir.mkdir(parents=True)
(stateDir / "updates_repo").write_text("bar 2.0-1 -> 2.1-1\n")
(stateDir / "updates_aur").write_text("foo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\n")
(stateDir / "updates_appman").write_text("someapp 1.2.0 -> 1.3.0\n")
(stateDir / "updates_all").write_text(
    "bar 2.0-1 -> 2.1-1\nfoo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\nsomeapp 1.2.0 -> 1.3.0\n")
(stateDir / "last_check").write_text(f"{int(time.time()) - 600}\n")

tray = runpy.run_path(str(REPO_ROOT / "src" / "cachyos-shelly-update-tray.py"), run_name="ci")

failures = []


def check(description, condition):
    print(("ok    " if condition else "FAIL  ") + description)
    if not condition:
        failures.append(description)


# Pure functions
humanDuration = tray["humanDuration"]
check("humanDuration(30)", humanDuration(30) == "less than 1 min")
check("humanDuration(600)", humanDuration(600) == "10 min")
check("humanDuration(3600)", humanDuration(3600) == "1 h")
check("humanDuration(5400)", humanDuration(5400) == "1 h 30 min")
check("humanDuration(2 days)", humanDuration(2 * 86400) == "2 d")
check("updatesAvailableText(1)", tray["updatesAvailableText"](1) == "1 update available")
check("updatesAvailableText(4)", tray["updatesAvailableText"](4) == "4 updates available")
check("readLines skips blank lines", tray["readLines"]("updates_aur") == ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"])
check("readLines of a missing file", tray["readLines"]("does_not_exist") == [])
check("kdeIconTheme reads kdeglobals", tray["kdeIconTheme"]() == "Papirus-Dark")

# Real tray and menu
app = tray["QApplication"](sys.argv)
tray["applyIconTheme"]()
QIcon = tray["QIcon"]
check("applyIconTheme uses KDE's theme when Qt has none", QIcon.themeName() == "Papirus-Dark")

trayApp = tray["TrayApp"](app)
check("tooltip shows the total", "4 updates available" in trayApp.tray.toolTip())

trayApp.buildMenu()
menuTexts = [action.text() for action in trayApp.menu.actions()]
subMenus = {action.text(): [item.text() for item in action.menu().actions()]
            for action in trayApp.menu.actions() if action.menu()}
print("      menu:", menuTexts)
check("menu shows the total", "4 updates available" in menuTexts)
check("Repositories (1) submenu", subMenus.get("Repositories (1)") == ["bar 2.0-1 -> 2.1-1"])
check("AUR (2) submenu", subMenus.get("AUR (2)") == ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"])
check("AppMan (1) submenu", subMenus.get("AppMan (1)") == ["someapp 1.2.0 -> 1.3.0"])
check("no submenu for an empty source", not any(text.startswith("Flatpak") for text in menuTexts))
check("submenus in source order", [t for t in menuTexts if "(" in t]
      == ["Repositories (1)", "AUR (2)", "AppMan (1)"])
check("last check", "Last check 10 min ago" in menuTexts)
check("fixed actions", {"Run CachyOS-Shelly-Update", "Check for updates", "Quit"} <= set(menuTexts))

# Long lists are cut off
(stateDir / "updates_aur").write_text("".join(f"pkg{i} 1 -> 2\n" for i in range(45)))
trayApp.buildMenu()
subMenus = {action.text(): [item.text() for item in action.menu().actions()]
            for action in trayApp.menu.actions() if action.menu()}
aurItems = subMenus.get("AUR (45)", [])
check("submenu limited to 40 items plus a note", len(aurItems) == 41 and aurItems[-1] == "... and 5 more")

# Up to date
for fileName in ("updates_repo", "updates_aur", "updates_appman", "updates_all"):
    (stateDir / fileName).write_text("")
trayApp.refresh()
trayApp.buildMenu()
menuTexts = [action.text() for action in trayApp.menu.actions()]
check("up to date: tooltip", "System is up to date" in trayApp.tray.toolTip())
check("up to date: menu", "System is up to date" in menuTexts)

print()
if failures:
    print(f"{len(failures)} test(s) failed")
    sys.exit(1)
print("all tests passed")
