# cachyos-shelly-update

> 🇧🇷 [Versão em português](./docs/pt-BR/README.md)

An updater in the style of [cachy-update](https://github.com/CachyOS/cachy-update) / [arch-update](https://github.com/Antiz96/arch-update) that uses **[Shelly](https://github.com/Seafoam-Labs/Shelly-ALPM)** as the backend and also updates **[AppMan](https://github.com/ivan-hc/AM)** apps. Repositories, AUR, Flatpak, AppImage and AppMan in one command, with automatic checks and a tray icon.

## What it does

- **`cachyos-shelly-update`** lists the updates grouped by source, asks, runs `shelly upgrade all` and then `appman -u`. Then it offers the cleanup (see [Cleanup](#cleanup)), shows pending `.pacnew` files and warns when the kernel changed.
- **Modular**: you pick the sources it handles (repositories, AUR, Flatpak, AppImage, AppMan) when installing. Only those are checked, updated and cleaned; a source you left out is never touched, even if its tool is installed.
- **Automatic checks**: a systemd timer runs `cachyos-shelly-update --check` 2 minutes after login and then every hour. A notification shows up when new updates appear. Checks never take pacman's database lock (see [No locks](#no-locks)), so they can't get in the way of pacman, Shelly or yay.
- **Tray icon**: looks and behaves like cachy-update's: the same icons, following `TrayIconStyle`, `ColorblindMode` and `ShowTrayWhenRelevant` from `arch-update.conf`, and the same menu.
  - Left click opens the updater in your default terminal emulator (see [Terminal](#terminal)).
  - Right click shows the number of updates, one entry per source with its count (Packages, AUR, Flatpak, AppImage, AppMan; only sources with updates), the last and next check, and "Run CachyOS-Shelly-Update", "Check for updates" and "Exit".

### Cleanup

After the update (and also when there was nothing to update, like cachy-update), each picked source is cleaned by its own tool:

| Source | What runs | What it removes |
|---|---|---|
| Repositories, AUR | `shelly purify standard --orphans --cache=1` | orphan packages, old versions in pacman's cache (keeps 1 of each), corrupted downloads |
| AUR | adds `--aur-cache`, **only if you say yes** (default no) | Shelly's AUR build cache: sources and builds, downloaded again on the next AUR update |
| Flatpak | `shelly purify flatpak` | unused runtimes and extensions |
| AppMan | `appman -c`, asked (default yes) | AppMan's cache, apps' cached files, launchers of removed apps, broken links in `~/.local/bin`, old modules |

Shelly lists what it would remove and asks before removing anything. The upgrade's own cache step is turned off (`--disable-cache-clean`), so the cache is cleaned once, here. Needs Shelly 3.2.0 or newer. With `-y` nothing is removed: the commands are printed instead. `--no-cleanup` skips it.

### AppMan

AppMan has no "check only" command: `appman -u` downloads right away. To list AppMan updates without applying them, cachyos-shelly-update runs only the first part of each app's `AM-updater` script, the part that reads the installed version and asks upstream for the latest one, and stops before the download. This works with the scripts generated from AppMan's templates (10,204 of the 10,206 apps in its catalog today); apps whose script doesn't follow them are left out of the list but are still updated by `appman -u`. Apps are checked 8 at a time, each with a 30-second limit (`CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT`); a check that runs out of time is stopped together with anything it started.

### Terminal

The tray opens the updater in the terminal emulator you use, found in this order:

1. `CACHYOS_SHELLY_UPDATE_TERMINAL`, if set (e.g. `kitty --single-instance`)
2. on KDE Plasma, the one picked in System Settings > Default Applications > Terminal emulator
3. `xdg-terminal-exec`, the freedesktop default terminal launcher (GNOME, Hyprland and others)
4. `$TERMINAL`
5. `x-terminal-emulator`
6. the first one installed of Konsole, Ghostty, kitty, Alacritty, foot, WezTerm, Ptyxis, Console, GNOME Terminal, Xfce Terminal and xterm

### No locks

- Repositories: `checkupdates` syncs a temporary copy of the databases, like arch-update. Shelly's own repository check syncs the real ones, which takes pacman's lock, so it is never used.
- AUR and AppImage: `shelly list-updates ... --json`, which only reads the local package database. The JSON output is used because Shelly's normal output is a formatted table.
- Flatpak and AppMan don't involve pacman.

If you start an update while a background check is running, it waits for the check to finish (up to 5 minutes, `CACHYOS_SHELLY_UPDATE_LOCK_TIMEOUT`) instead of failing.

### Performance

The sources are checked in parallel (Shelly's own calls stay one after another), so a check takes about as long as the slowest source instead of the sum of all of them. The code is precompiled at install time and the CLI starts Python without `site` (`-I -S`), so the timer's check costs little more than the commands it runs.

AppMan is skipped when it isn't installed or has never been set up (no `~/.config/appman/appman-config`). Use `--no-appman` to turn it off.

## Installation

```bash
git clone <this-repo-url> cachyos-shelly-update
cd cachyos-shelly-update
./install.sh install
```

Run it as your **normal user**: the script asks for `sudo` when it needs to, and `yay` and AppMan refuse to run as root.

The installer:

1. Asks to install **yay** when there is no AUR helper (yay or paru): from the repositories (CachyOS has it), or built from the AUR (`yay-bin`) otherwise.
2. Checks for and installs the dependencies: `shelly`, `python`, `pacman-contrib`, `libnotify` and `curl`, plus tools AppMan uses to unpack apps (`wget`, `unzip`, `7zip`, `binutils`, `file`, `xz`; optional).
   It looks in the repositories first (CachyOS already ships Shelly). If a package isn't there and yay or paru is installed, it uses the `-bin` version from the AUR. Packages that only *provide* a dependency, like `shelly-bin`, count too.
3. Shows the list of **update sources** (repositories, AUR, Flatpak, AppImage, AppMan): toggle with the numbers, Enter to apply. What is installed is picked to start with. A picked source whose tool is missing is offered for install:
   - **Flatpak**, with Shelly's Flatpak backend and the **Flathub** remote;
   - **AppMan**, in `~/.local/bin/appman`, the same way AppMan's own installer does. It isn't configured: the first `appman -i <app>` asks where to keep apps.

   A source left out stays off even if its tool is installed. The choice is saved in `/opt/cachyos-shelly-update/sources` and kept by `update`; `install.sh sources` shows the list again.
5. Copies the files to **`/opt/cachyos-shelly-update`**. The installation doesn't depend on the repository, so the clone can be deleted afterwards.
6. Creates the project's Python virtualenv in `/opt/cachyos-shelly-update/.venv` with the tray's dependency (PyQt6, pinned in `requirements.txt`), so nothing is added to the system Python. The command and the tray both run on it. The command only needs the standard library, so if the virtualenv is ever broken (its Python gone, a rebuild that failed) it runs on the system `python3` instead, and the hourly check keeps working. A pacman hook rebuilds the virtualenv and the precompiled code when the `python` package moves to a new version.
7. Creates the `/usr/local/bin/cachyos-shelly-update` link, the app menu entry, the tray autostart and the systemd user timer.
8. Turns cachy-update off, so you don't get two tray icons and two checks: its timer (per user or for all users), its tray at login and the running tray. The package and its files stay untouched; the tray is switched off for your user with an `~/.config/autostart/arch-update-tray.desktop` file containing `Hidden=true` (your own copy of that file, if any, is backed up). What was on is recorded.

## Updating and removing

```bash
/opt/cachyos-shelly-update/install.sh update              # fetch the new version from git and reinstall
/opt/cachyos-shelly-update/install.sh sources             # pick the update sources again
/opt/cachyos-shelly-update/install.sh uninstall           # remove it (dependencies stay)
/opt/cachyos-shelly-update/install.sh uninstall --purge   # also delete your state/config and offer to
                                                          # remove the packages and AppMan it installed
/opt/cachyos-shelly-update/install.sh status              # version, dependencies, virtualenv, timer and tray
```

`update` uses the `origin` URL saved at install time. To change it, run it with `CACHYOS_SHELLY_UPDATE_REPO=<url>`. If you run `update` from inside a clone, it does a `git pull` and reinstalls.

Any installed version can update to the latest one: the installed `install.sh` downloads the new version and runs the new installer, which turns whatever layout an older version left into exactly what a fresh install gives. Files the new version no longer installs are removed (the installer keeps a list of what it put where, in `/opt/cachyos-shelly-update/installed-files`), the virtualenv is rebuilt only when `requirements.txt` or the Python version changed, the code is recompiled, the systemd units are reloaded and the running tray is restarted on the new code, in its own session, even when the update runs from a TTY, SSH or `sudo`. Your settings, state and the installer's records are kept. CI checks this for every earlier release (`tests/self_update.sh`).

Uninstalling always removes the virtualenv with everything else in `/opt/cachyos-shelly-update`. If cachy-update was on before the install, it asks whether to turn it back on (default: yes) and restores exactly what was on, including your own autostart file. With `--purge` it also offers to remove what the installer added: only the packages it installed itself (each one is kept if another package still needs it) and AppMan, if it downloaded it. Apps you installed with AppMan are never touched.

`-y` / `--yes` answers everything automatically (pacman and yay get `--noconfirm`); without a saved choice it picks every source you didn't turn down before and installs its tools.

## Usage

| Command | Description |
|---|---|
| `cachyos-shelly-update` | list, ask and update |
| `cachyos-shelly-update -l` | only list |
| `cachyos-shelly-update -y` | update without asking |
| `cachyos-shelly-update -c` | silent check (the one the timer uses) |
| `cachyos-shelly-update --tray` | start the tray icon |
| `--no-repo` `--no-aur` `--no-flatpak` `--no-appimage` `--no-appman` `--no-devel` | skip sources (on top of the installer's choice) |
| `--no-cleanup` | don't offer the cleanup |

To make options permanent, create `~/.config/cachyos-shelly-update/cachyos-shelly-update.conf` with one option per line. There is an example in `/opt/cachyos-shelly-update/cachyos-shelly-update.conf.example`.

To change the check interval:

```bash
systemctl --user edit cachyos-shelly-update.timer
```

## Layout

```
install.sh                         install / update / uninstall / status
VERSION                            bump on every release (update compares against it)
requirements.txt                   the tray's Python dependencies (pinned)
requirements-dev.txt               CI and development tools: ruff, mypy, pytest (pinned)
ruff.toml, mypy.ini                lint rules and type checking settings
src/cachyos-shelly-update          launcher (sh): the venv's Python, or python3 if the venv is broken
src/shellyupdate/                  the Python package:
  core.py                          paths, sources, state files and texts shared by the CLI and the tray
  sources.py                       the update checks (repositories, AUR, Flatpak, AppImage, AppMan)
  cli.py                           the command line updater
  terminal.py                      finds the default terminal emulator
  tray.py                          tray icon (PyQt6)
data/                              .desktop files, systemd units, pacman hook, config example
tests/                             tests run by CI (they don't touch the system)
docs/pt-BR/                        Portuguese documentation
```

## Tests and CI

The GitLab pipeline runs on every merge request and every push to `main`:

- **lint**: `shellcheck` on `install.sh`, the launcher and the test scripts; `ruff` on the Python (rules in `ruff.toml`); `mypy`, strict on the package (every function typed) and on the tests' code (`mypy.ini`); and validation of the `.desktop` files and the systemd units.
- **test**: `tests/test_units.py` (run with pytest, so the merge request shows the test report and the unit tests' coverage) tests the package's pieces (the AppMan probe and its timeout, the parallel checks, options, icons, the terminal lookup). `tests/smoke.sh` runs the real updater against fake `shelly` and `appman` commands, with a temporary HOME and no sudo, including AppMan apps built from each template layout. `tests/cachy_update_handoff.sh` checks that installing turns cachy-update off and uninstalling turns back on exactly what was on, with fake `systemctl`; `tests/installer_tools.sh` checks the optional tools (yay, Flatpak + Flathub, AppMan). `tests/self_update.sh` installs every earlier release from git history, updates it with its own `install.sh update` and checks the result equals a fresh install (files, venv, units, tray restart, state), plus the launcher's fallback to `python3`. `tests/tray_smoke.py` builds the tray and its menu without a display, and checks that "Run" opens the KDE default terminal.

To run them locally:

```bash
shellcheck install.sh tests/*.sh src/cachyos-shelly-update
pip install -r requirements.txt -r requirements-dev.txt
ruff check .
mypy
PYTHONPATH=src python -m pytest tests/test_units.py   # or: python -m unittest discover -s tests
bash tests/smoke.sh
bash tests/cachy_update_handoff.sh
bash tests/installer_tools.sh
bash tests/self_update.sh         # in a container: it runs as a throwaway user when root
PYTHONPATH=src QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
```

## Installed files

| Path | Contents |
|---|---|
| `/opt/cachyos-shelly-update/` | the program, `install.sh`, `VERSION`, `REPO`, the `.venv` virtualenv, `installed-files` (what the installer put where), `sources` (the picked sources) |
| `/usr/local/bin/cachyos-shelly-update` | link to the command |
| `/usr/local/share/applications/cachyos-shelly-update.desktop` | app menu entry |
| `/etc/xdg/autostart/cachyos-shelly-update-tray.desktop` | tray at session start |
| `/etc/systemd/user/cachyos-shelly-update.{service,timer}` | automatic checks |
| `/etc/pacman.d/hooks/cachyos-shelly-update-venv.hook` | rebuilds the virtualenv after Python upgrades |
| `~/.local/bin/appman` | AppMan, if the installer downloaded it |
| `~/.local/state/cachyos-shelly-update/` | state (updates per source, current icon) |

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).
