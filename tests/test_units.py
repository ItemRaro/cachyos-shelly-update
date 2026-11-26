"""Unit tests for the shellyupdate package (standard library only).

    PYTHONPATH=src python -m unittest discover -s tests -p "test_*.py"
"""

import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

# core reads the XDG paths at import time: point them at a temporary home first
TEMP_ROOT = Path(tempfile.mkdtemp(prefix="shellyupdate-tests."))
os.environ.update({
    "HOME": str(TEMP_ROOT / "home"),
    "XDG_STATE_HOME": str(TEMP_ROOT / "state"),
    "XDG_CONFIG_HOME": str(TEMP_ROOT / "config"),
    "XDG_RUNTIME_DIR": str(TEMP_ROOT / "run"),
})
for directory in ("home", "state", "config", "run"):
    (TEMP_ROOT / directory).mkdir()
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from shellyupdate import cli, core, sources, terminal  # noqa: E402


def tearDownModule():
    shutil.rmtree(TEMP_ROOT, ignore_errors=True)


class CoreTests(unittest.TestCase):
    def setUp(self):
        core.STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.archUpdateConfig = core.ARCH_UPDATE_CONFIG_FILE
        self.archUpdateConfig.parent.mkdir(parents=True, exist_ok=True)
        self.archUpdateConfig.unlink(missing_ok=True)

    def testFormatDurationLikeCachyUpdate(self):
        cases = {30: "30s", 600: "10m", 3600: "1h", 5403: "1h 30m 3s", 2 * 86400: "2d",
                 90060: "1d 1h 1m", 0: None, -5: None}
        for seconds, expected in cases.items():
            self.assertEqual(core.formatDuration(seconds), expected)

    def testShowTrayWhenRelevant(self):
        self.assertFalse(core.showTrayWhenRelevant())
        self.archUpdateConfig.write_text("TrayIconStyle=blue\n  ShowTrayWhenRelevant\n")
        self.assertTrue(core.showTrayWhenRelevant())
        self.archUpdateConfig.write_text("#ShowTrayWhenRelevant\n")
        self.assertFalse(core.showTrayWhenRelevant())

    def testRepositoriesAreCalledPackagesLikeCachyUpdate(self):
        self.assertEqual(dict(core.SOURCES)["repo"], "Packages")

    def testUpdatesAvailableText(self):
        self.assertEqual(core.updatesAvailableText(1), "1 update available")
        self.assertEqual(core.updatesAvailableText(3), "3 updates available")

    def testStateFilesAndCounts(self):
        core.writeStateFile("updates_repo", "a 1 -> 2\n\nb 1 -> 2\n")
        core.writeStateFile("updates_aur", "c 1 -> 2\n")
        self.assertEqual(core.readLines("updates_repo"), ["a 1 -> 2", "b 1 -> 2"])
        self.assertEqual(core.countUpdates(["repo", "aur", "missing"]), 3)
        self.assertFalse(list(core.STATE_DIR.glob("*.tmp")), "temporary files left behind")

    def testTrayIconDefaults(self):
        self.assertEqual(core.currentTrayIcon(False), "cachy-update-blue")
        self.assertEqual(core.currentTrayIcon(True), "cachy-update_updates-available-blue")

    def testTrayIconFollowsArchUpdateConfig(self):
        self.archUpdateConfig.write_text("TrayIconStyle = light\nColorblindMode\nTrayIconStyle=dark\n")
        self.assertEqual(core.currentTrayIcon(True), "cachy-update_updates-available-dark-cb")
        self.assertEqual(core.currentTrayIcon(False), "cachy-update-dark")

    def testUnknownTrayIconStyleFallsBack(self):
        self.archUpdateConfig.write_text("TrayIconStyle=purple\n")
        self.assertEqual(core.currentTrayIcon(False), "cachy-update-blue")


class ShellyOutputTests(unittest.TestCase):
    """Shelly's --json output (its plain output is a table, never parsed)."""

    def shellyPrints(self, output):
        return mock.patch.object(sources, "runQuiet", return_value=output)

    def testAurJson(self):
        output = '[{"Name":"foo-bin","Version":"1.0-1","NewVersion":"1.1-1","Url":"x"},{"Version":"9"}]'
        with self.shellyPrints(output) as runQuiet:
            self.assertEqual(sources.checkAur(skipDevel=True), ["foo-bin 1.0-1 -> 1.1-1"])
        command = runQuiet.call_args.args[0]
        self.assertEqual(command, ["shelly", "list-updates", "aur", "--no-devel", "--json"])

    def testAppimageJsonOnlyCountsAvailableUpdates(self):
        output = ('[{"Name":"Tool","Version":"2.0","IsUpdateAvailable":true},'
                  '{"Name":"Other","Version":"1.0","IsUpdateAvailable":false}]')
        with self.shellyPrints(output):
            self.assertEqual(sources.checkAppimage(), ["Tool -> 2.0"])

    def testNothingToDo(self):
        with self.shellyPrints("[]"):
            self.assertEqual(sources.checkAur(skipDevel=False), [])

    def testPlainTextOrGarbageIsNeverCounted(self):
        """Regression: Shelly's table and messages were counted as updates."""
        for output in ("No appimage updates available\n", "│ Name │ Installed │\n", "", "{}", "[1, 2]"):
            with self.shellyPrints(output):
                self.assertEqual(sources.checkAppimage(), [], output)
                self.assertEqual(sources.checkAur(skipDevel=False), [], output)

    def testRepositoriesNeverUseShelly(self):
        """Shelly's standard check syncs the real databases (pacman's lock)."""
        with mock.patch("shellyupdate.sources.shutil.which", return_value=None), self.shellyPrints("x") as runQuiet:
            self.assertEqual(sources.checkRepo(), [])
        runQuiet.assert_not_called()

    def testShortVersion(self):
        cases = {
            "https://example.com/v1.2.0/App-1.2.0-x86_64.AppImage": "1.2.0",
            "https://example.com/App.AppImage?raw=1": "App.AppImage",
            "26.08.3": "26.08.3",
            "": "?",
        }
        for version, expected in cases.items():
            self.assertEqual(sources.shortVersion(version), expected)


class AppmanProbeTests(unittest.TestCase):
    TEMPLATE = (
        '#!/bin/sh\nset -u\nAPP=app\nSITE="x/y"\n'
        'version0=$(cat "/opt/$APP/version")\n'
        'version=$(curl -Ls https://api.github.com/repos/x/y/releases | head -1)\n'
        '[ -n "$version" ] || { echo "Error getting link"; exit 1; }\n'
        'if [ "$version" != "$version0" ]; then\n\twget "$version"\nfi\n'
    )

    def testProbeStopsBeforeTheDownload(self):
        probe = sources.buildAppmanProbe(self.TEMPLATE)
        if probe is None:
            self.fail("the template wasn't recognized")
        self.assertNotIn("wget", probe)
        self.assertNotIn('[ -n "$version" ]', probe)
        self.assertTrue(probe.rstrip().endswith('"$version0" "$version"'))

    def testOneLineCaseTemplate(self):
        script = ('version0=$(cat v)\ncase "$SITE" in\n\t"a/b") version=$(echo 1);;\n'
                  '\t*) version=$(echo 2);;\nesac\n[ -n "$version" ] || exit 1\n')
        self.assertIsNotNone(sources.buildAppmanProbe(script))

    def testIndentedCaseTemplate(self):
        script = 'version0=$(cat v)\ncase "$SITE" in\n\t*)\n\tversion=$(echo 2)\n\t;;\nesac\nif true; then :; fi\n'
        self.assertIsNotNone(sources.buildAppmanProbe(script))

    def testScriptsOffTheTemplateAreSkipped(self):
        self.assertIsNone(sources.buildAppmanProbe("#!/bin/sh\ntouch downloaded\n"))
        self.assertIsNone(sources.buildAppmanProbe("version0=$(cat v)\nif x; then version=1; fi\n"))

    def testProbeReturnsBothVersions(self):
        with tempfile.TemporaryDirectory() as appDir:
            versions = sources.runAppmanProbe('version0=old\nversion=new\nprintf "%s\\n%s\\n" "$version0" "$version"\n',
                                              Path(appDir))
        self.assertEqual(versions, ("old", "new"))

    def testTimeoutKillsTheWholeProcessGroup(self):
        """A stuck child (a hanging curl) must not outlive the probe."""
        with tempfile.TemporaryDirectory() as appDir:
            lateMarker = Path(appDir) / "late"
            probe = f'(sleep 2; touch "{lateMarker}") &\nsleep 30\n'
            with mock.patch.object(sources, "APPMAN_PROBE_TIMEOUT", 0.5):
                startTime = time.monotonic()
                self.assertIsNone(sources.runAppmanProbe(probe, Path(appDir)))
                self.assertLess(time.monotonic() - startTime, 5)
            time.sleep(2.5)
            self.assertFalse(lateMarker.exists(), "a child of the timed-out probe kept running")


class CheckAllTests(unittest.TestCase):
    def testChecksRunInParallelAndShellyCallsDont(self):
        activeShellyCalls, overlaps = [0], []
        guard = threading.Lock()

        def slowShellyCheck(*_):
            with guard:
                activeShellyCalls[0] += 1
                overlaps.append(activeShellyCalls[0])
            time.sleep(0.4)
            with guard:
                activeShellyCalls[0] -= 1
            return ["x"]

        def slowCheck(*_):
            time.sleep(0.4)
            return ["y"]

        with mock.patch.multiple(sources, checkRepo=slowCheck, checkAur=slowShellyCheck,
                                 checkAppimage=slowShellyCheck, checkFlatpak=slowCheck,
                                 checkAppman=slowCheck):
            startTime = time.monotonic()
            results = sources.checkAll(set(core.SOURCE_KEYS), skipDevel=False)
            elapsed = time.monotonic() - startTime

        self.assertEqual(results, {"repo": ["y"], "aur": ["x"], "appimage": ["x"],
                                   "flatpak": ["y"], "appman": ["y"]})
        self.assertEqual(max(overlaps), 1, "two Shelly calls ran at the same time")
        # 2 Shelly calls in sequence (0.8 s) while the others run alongside
        self.assertLess(elapsed, 1.3)

    def testDisabledSourcesAreNotChecked(self):
        calls: list[str] = []

        def recordCall(key: str):
            def check(*_: object) -> list[str]:
                calls.append(key)
                return []
            return check

        with mock.patch.multiple(sources, checkRepo=recordCall("repo"), checkAur=recordCall("aur"),
                                 checkAppimage=recordCall("appimage"), checkFlatpak=recordCall("flatpak"),
                                 checkAppman=recordCall("appman")):
            sources.checkAll({"aur", "flatpak"}, skipDevel=True)
        self.assertEqual(sorted(calls), ["aur", "flatpak"])


class OptionTests(unittest.TestCase):
    def setUp(self):
        core.CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        core.CONFIG_FILE.unlink(missing_ok=True)

    def testDefaults(self):
        options = cli.parseOptions([], "1.0")
        self.assertEqual(options.mode, "update")
        self.assertEqual(options.enabledSources, set(core.SOURCE_KEYS))

    def testConfigFileThenCommandLine(self):
        core.CONFIG_FILE.write_text("# comment\n--no-aur   # no AUR\n\n  --no-devel\n--list\n")
        options = cli.parseOptions(["--check", "--no-appman"], "1.0")
        self.assertEqual(options.mode, "check")
        self.assertTrue(options.skipDevel)
        self.assertEqual(options.enabledSources, set(core.SOURCE_KEYS) - {"aur", "appman"})

    def testAppmanCompatibilityOption(self):
        options = cli.parseOptions(["--no-appman", "--appman"], "1.0")
        self.assertIn("appman", options.enabledSources)

    def testUnknownOptionExitsWithOne(self):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit) as exitInfo:
            cli.parseOptions(["--bogus"], "1.0")
        self.assertEqual(exitInfo.exception.code, 1)

    def testNoDashForUnknownSource(self):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            cli.parseOptions(["--no-snap"], "1.0")


class TerminalTests(unittest.TestCase):
    """The default terminal lookup, with fake terminal executables on PATH."""

    def setUp(self):
        self.binDir = Path(tempfile.mkdtemp(prefix="terminals.", dir=TEMP_ROOT))
        self.configHome = Path(tempfile.mkdtemp(prefix="config.", dir=TEMP_ROOT))
        self.environment = mock.patch.dict(os.environ, {"PATH": str(self.binDir)}, clear=False)
        self.environment.start()
        for variable in (terminal.OVERRIDE_VARIABLE, "TERMINAL", "XDG_CURRENT_DESKTOP"):
            os.environ.pop(variable, None)

    def tearDown(self):
        self.environment.stop()

    def install(self, *names):
        for name in names:
            executable = self.binDir / name
            executable.write_text("#!/bin/sh\n")
            executable.chmod(0o755)

    def setKdeTerminal(self, value):
        os.environ["XDG_CURRENT_DESKTOP"] = "KDE"
        (self.configHome / "kdeglobals").write_text(f"[General]\nTerminalApplication={value}\n")

    def command(self):
        return terminal.terminalCommand(["updater", "--wait"], self.configHome)

    def testKdeDefaultWinsOverEverythingButTheOverride(self):
        self.install("ghostty", "alacritty", "konsole", "xdg-terminal-exec")
        os.environ["TERMINAL"] = "alacritty"
        self.setKdeTerminal("ghostty")
        self.assertEqual(self.command(), ["ghostty", "-e", "updater", "--wait"])

    def testOverrideWins(self):
        self.install("ghostty", "kitty")
        self.setKdeTerminal("ghostty")
        os.environ[terminal.OVERRIDE_VARIABLE] = "kitty --single-instance"
        self.assertEqual(self.command(), ["kitty", "--single-instance", "updater", "--wait"])

    def testKdeSettingIsIgnoredOutsideKde(self):
        self.install("ghostty", "alacritty")
        (self.configHome / "kdeglobals").write_text("[General]\nTerminalApplication=ghostty\n")
        os.environ["XDG_CURRENT_DESKTOP"] = "GNOME"
        os.environ["TERMINAL"] = "alacritty"
        self.assertEqual(self.command()[0], "alacritty")

    def testXdgTerminalExecBeforeTerminalVariable(self):
        self.install("xdg-terminal-exec", "alacritty")
        os.environ["TERMINAL"] = "alacritty"
        self.assertEqual(self.command(), ["xdg-terminal-exec", "updater", "--wait"])

    def testTerminalVariable(self):
        self.install("foot", "alacritty")
        os.environ["TERMINAL"] = "foot"
        self.assertEqual(self.command(), ["foot", "updater", "--wait"])

    def testUninstalledChoiceFallsThrough(self):
        self.install("alacritty")
        self.setKdeTerminal("ghostty")
        self.assertEqual(self.command()[0], "alacritty")

    def testFallbackOrderStartsWithKonsole(self):
        self.install("xterm", "kitty", "konsole")
        self.assertEqual(self.command()[0], "konsole")

    def testExecuteArgumentsPerTerminal(self):
        cases = {"kitty": [], "foot": [], "wezterm": ["start", "--"], "gnome-terminal": ["--"],
                 "ptyxis": ["--"], "xfce4-terminal": ["-x"], "ghostty": ["-e"], "konsole": ["-e"]}
        for name, arguments in cases.items():
            self.assertEqual(terminal.withExecuteArguments([f"/usr/bin/{name}"], ["cmd"]),
                             [f"/usr/bin/{name}", *arguments, "cmd"])

    def testNoTerminalAtAll(self):
        self.assertIsNone(self.command())


class LockTests(unittest.TestCase):
    """Our single-instance lock: the timer skips, an interactive run waits."""

    def holdLock(self, seconds: float) -> None:
        import fcntl
        holder = core.openLockFile(core.LOCK_FILE)
        fcntl.flock(holder, fcntl.LOCK_EX)
        threading.Timer(seconds, os.close, args=(holder,)).start()

    def testCheckSkipsRightAway(self):
        self.holdLock(1)
        startTime = time.monotonic()
        self.assertIsNone(cli.acquireLock(0))
        self.assertLess(time.monotonic() - startTime, 0.5)
        time.sleep(1.2)

    def testInteractiveRunWaitsForTheCheck(self):
        self.holdLock(1)
        with mock.patch("sys.stdout"):
            lock = cli.acquireLock(10)
        if lock is None:
            self.fail("the lock was never acquired")
        os.close(lock)

    def testInteractiveRunGivesUp(self):
        self.holdLock(2)
        with mock.patch("sys.stdout"):
            self.assertIsNone(cli.acquireLock(0.6))
        time.sleep(1.6)


if __name__ == "__main__":
    unittest.main()
