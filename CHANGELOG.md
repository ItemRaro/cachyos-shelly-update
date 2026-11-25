# Changelog

All notable changes to this project are documented in this file. The
Portuguese version, with the same changes, is in
[docs/pt-BR/CHANGELOG.md](docs/pt-BR/CHANGELOG.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.2.0...main
[1.2.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.1.0...v1.2.0
[1.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.0.0...v1.1.0
[1.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/tags/v1.0.0
