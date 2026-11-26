# Changelog

All notable changes to this project are documented in this file. The
Portuguese version, with the same changes, is in
[docs/pt-BR/CHANGELOG.md](docs/pt-BR/CHANGELOG.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.2.0] - 2026-11-26

### Changed
- One virtualenv for the whole project: the command runs on
  `/opt/cachyos-shelly-update/.venv`'s Python too, not only the tray. If the
  virtualenv is broken (its Python gone, a failed rebuild), the command falls
  back to the system `python3`, so the hourly check never stops. The
  launcher is now a small `sh` script. `install.sh status` shows which
  Python the command runs on.

### Fixed
- Updating from any earlier version now always ends up exactly like a fresh
  install, and CI proves it for every release (`tests/self_update.sh`):
  - the installer records what it installs (`installed-files`) and removes
    what a newer version no longer installs, also on uninstall;
  - the running tray is restarted on the new code in its own session even
    when the update runs from a TTY, SSH or `sudo`; before, only an update
    started from a terminal inside the desktop restarted it, and an old tray
    kept running on deleted code.


## [2.1.0] - 2026-11-25

### Fixed
- The tray icon always showed "updates available", and an empty AppImage
  entry appeared in the menu: Shelly's output is a formatted table, and its
  headers, borders and messages (like "No appimage updates available") were
  counted as updates. The AUR and AppImage checks now read
  `shelly list-updates ... --json`, and AppImages only count when Shelly
  marks them `IsUpdateAvailable`.
- Starting an update while a background check ran failed with "already
  running"; it now waits for the check (up to 5 minutes).

### Changed
- The tray menu is cachy-update's, with counts instead of package lists:
  the total, one "Source (N)" entry per source with updates, last and next
  check in its "1h 5m" format, then Run, Check for updates and Exit.
  `ShowTrayWhenRelevant` from `arch-update.conf` hides the icon while up to
  date. "Repositories" is now "Packages", as in cachy-update.
- The timer checks every hour (was 6 hours). No check takes pacman's lock:
  the Shelly fallback for the repositories, which synced the real databases,
  is gone; `checkupdates` is always used.
- The installer asks to install what's missing instead of requiring or
  silently adding it: yay (from the repositories, or `yay-bin` from the AUR),
  Flatpak with Shelly's Flatpak backend and Flathub, and AppMan. A "no" is
  remembered until uninstall. Flatpak is no longer a hard dependency; the
  updater skips it when it isn't installed.
- The installer's questions show up even when answers are piped in.

## [2.0.0] - 2026-11-25

### Changed
- The updater is rewritten in Python (standard library only, run by the
  system's `python3`); `install.sh` stays in bash. Commands, options, the
  config file, the state files, the systemd units and the tray are the same,
  so a 1.x install upgrades in place.
- The CLI and the tray share one package (`shellyupdate`): sources, state
  files, texts and icons are defined once.
- The sources are checked in parallel, and AppMan apps 8 at a time. Shelly's
  own calls still run one after another. With network-like delays a check
  went from 7.6 s to 2.1 s in a benchmark; with instant sources both take
  about 0.1 s.
- The code is precompiled at install time, and the pacman hook recompiles it
  after Python upgrades.

### Added
- The tray opens the updater in the user's default terminal emulator: the
  KDE Plasma setting, `xdg-terminal-exec`, `$TERMINAL` or
  `x-terminal-emulator`, before a list of known terminals.
  `CACHYOS_SHELLY_UPDATE_TERMINAL` still overrides it.
- Unit tests for the package (`tests/test_units.py`), next to the 1.x smoke
  tests, which still run unchanged against the new code.

### Fixed
- The tray opened the first terminal it found (e.g. Alacritty) instead of
  the one set as default (e.g. Ghostty).
- An AppMan check that timed out now also stops what it started (a stuck
  `curl`), not just its shell.

## [1.2.0] - 2026-11-25

### Changed
- Installing turns cachy-update off without asking (two trays and two
  checks would compete) and records what was on: its timer, per user or for
  all users, its tray at login and the running tray.
- Uninstalling asks whether to turn cachy-update back on when it was on
  before the install, and restores exactly that, including the user's own
  `~/.config/autostart/arch-update-tray.desktop`.
- `install.sh status` shows whether cachy-update was turned off by the
  installer.

### Fixed
- cachy-update's tray came back at the next login: the CachyOS package
  starts it from `/etc/xdg/autostart/arch-update-tray.desktop`, which the
  installer didn't handle. It is now switched off for the user with an XDG
  override (`Hidden=true`), without touching the package's files.
- The installer no longer tries to disable `arch-update-tray.service`, which
  cachy-update doesn't have.

## [1.1.0] - 2026-11-25

### Added
- AppMan is a full update source: its updates are checked by the timer,
  listed per app in the terminal, the notification and a new "AppMan" tray
  submenu, and applied with `appman -u` in the same run as Shelly. Checking
  runs only the version lookup at the top of each app's `AM-updater` (never
  the download), with a 30-second limit per app
  (`CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT`).
- `--no-appman` to skip AppMan.
- The installer installs AppMan in `~/.local/bin/appman` when it's missing,
  plus the tools AppMan uses to unpack apps (`wget`, `unzip`, `7zip`,
  `binutils`, `file`, `xz`; optional).
- The tray's Python dependency (PyQt6) is installed into a private
  virtualenv in `/opt/cachyos-shelly-update/.venv`, pinned in
  `requirements.txt`, instead of the system's `python-pyqt6`.
- A pacman hook rebuilds that virtualenv when the `python` package moves to a
  new minor version (a virtualenv stops working when that happens).
- `install.sh uninstall --purge` offers to remove the packages the installer
  added and AppMan, if the installer downloaded it. Apps installed with
  AppMan are never removed.
- `install.sh status` shows AppMan and the state of the virtualenv.
- The tray follows the KDE icon theme (`kdeglobals`) even though PyQt6 from
  pip has no KDE platform plugin.
- GitLab CI: shellcheck, ruff, `.desktop` and systemd unit validation, and
  smoke tests that run the real scripts against fake `shelly`/`appman`.
- English documentation; the Portuguese one moved to `docs/pt-BR/`.

### Changed
- AppMan is on by default when it's installed and set up. `--appman` is still
  accepted, but does nothing new.
- All program messages, code and comments are in English. The `.desktop`
  entries keep Portuguese translations (`[pt_BR]`).
- Code style: camelCase variables and functions, PascalCase classes,
  ALL_CAPS constants.
- `python-pyqt6` is no longer a dependency (replaced by the virtualenv);
  `python` and `curl` are.

### Fixed
- The `update` command's temporary directory is now always removed on exit
  (the cleanup trap captured the path too early).
- shellcheck findings in `install.sh` and the updater: commands and checks
  are dispatched with explicit `case` statements, and `A && B || C` chains
  became `if` blocks.

## [1.0.0] - 2026-11-25

### Added
- First version: `cachyos-shelly-update` lists, confirms and applies updates
  from the repositories, AUR, Flatpak and AppImage through Shelly, with
  `.pacnew`, orphan and kernel checks afterwards.
- systemd user timer for background checks, with notifications.
- PyQt6 tray icon using cachy-update's icons.
- `install.sh` with install, update, uninstall and status.

[Unreleased]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v2.2.0...main
[2.2.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v2.1.0...v2.2.0
[2.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v2.0.0...v2.1.0
[2.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.2.0...v2.0.0
[1.2.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.1.0...v1.2.0
[1.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.0.0...v1.1.0
[1.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/tags/v1.0.0
