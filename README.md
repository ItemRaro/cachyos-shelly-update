# cachyos-shelly-update

> 🇧🇷 [Versão em português](./docs/pt-BR/README.md)

An updater in the style of [cachy-update](https://github.com/CachyOS/cachy-update) / [arch-update](https://github.com/Antiz96/arch-update) that uses **[Shelly](https://github.com/Seafoam-Labs/Shelly-ALPM)** as the backend and also updates **[AppMan](https://github.com/ivan-hc/AM)** apps. Repositories, AUR, Flatpak, AppImage and AppMan in one command, with automatic checks and a tray icon.

## What it does

- **`cachyos-shelly-update`** lists the updates grouped by source, asks, runs `shelly upgrade all` and then `appman -u`. Afterwards it shows pending `.pacnew` files and orphan packages, and warns when the kernel changed.
- **Automatic checks**: a systemd timer runs `cachyos-shelly-update --check` 2 minutes after login and then every 6 hours. A notification shows up when new updates appear.
- **Tray icon**: uses cachy-update's icons and honors `TrayIconStyle` from `arch-update.conf`.
  - Left click opens the updater in a terminal.
  - Right click shows the updates per source, the last and next check, and "Check for updates" and "Quit".

### AppMan

AppMan has no "check only" command: `appman -u` downloads right away. To list AppMan updates without applying them, cachyos-shelly-update runs only the first part of each app's `AM-updater` script, the part that reads the installed version and asks upstream for the latest one, and stops before the download. This works with the scripts generated from AppMan's templates (10,204 of the 10,206 apps in its catalog today); apps whose script doesn't follow them are left out of the list but are still updated by `appman -u`. Each check has a 30-second limit (`CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT`).

AppMan is skipped when it isn't installed or has never been set up (no `~/.config/appman/appman-config`). Use `--no-appman` to turn it off.

## Installation

```bash
git clone <this-repo-url> cachyos-shelly-update
cd cachyos-shelly-update
./install.sh install
```

Run it as your **normal user**: the script asks for `sudo` when it needs to, and `yay` and AppMan refuse to run as root.

The installer:

1. Checks for and installs the dependencies: `shelly`, `shelly-flatpak-backend`, `flatpak`, `python`, `pacman-contrib`, `libnotify` and `curl`, plus tools AppMan uses to unpack apps (`wget`, `unzip`, `7zip`, `binutils`, `file`, `xz`; optional).
   It looks in the repositories first (CachyOS already ships Shelly). If a package isn't there and **yay** is installed, it uses the `-bin` version from the AUR. Packages that only *provide* a dependency, like `shelly-bin`, count too.
2. Installs **AppMan** in `~/.local/bin/appman` if you don't have it, the same way AppMan's own installer does. It isn't configured: the first `appman -i <app>` asks where to keep apps.
3. Copies the files to **`/opt/cachyos-shelly-update`**. The installation doesn't depend on the repository, so the clone can be deleted afterwards.
4. Creates a private Python virtualenv in `/opt/cachyos-shelly-update/.venv` with the tray's dependency (PyQt6, pinned in `requirements.txt`), so nothing is added to the system Python. A pacman hook rebuilds it when the `python` package moves to a new version.
5. Creates the `/usr/local/bin/cachyos-shelly-update` link, the app menu entry, the tray autostart and the systemd user timer.
6. If cachy-update is active, offers to disable its timer and tray so you don't get two icons. Its package stays installed.

## Updating and removing

```bash
/opt/cachyos-shelly-update/install.sh update              # fetch the new version from git and reinstall
/opt/cachyos-shelly-update/install.sh uninstall           # remove it (dependencies stay)
/opt/cachyos-shelly-update/install.sh uninstall --purge   # also delete your state/config and offer to
                                                          # remove the packages and AppMan it installed
/opt/cachyos-shelly-update/install.sh status              # version, dependencies, virtualenv, timer and tray
```

`update` uses the `origin` URL saved at install time. To change it, run it with `CACHYOS_SHELLY_UPDATE_REPO=<url>`. If you run `update` from inside a clone, it does a `git pull` and reinstalls.

Uninstalling always removes the virtualenv with everything else in `/opt/cachyos-shelly-update`. With `--purge` it also offers to remove what the installer added: only the packages it installed itself (each one is kept if another package still needs it) and AppMan, if it downloaded it. Apps you installed with AppMan are never touched.

`-y` / `--yes` answers everything automatically (pacman and yay get `--noconfirm`).

## Usage

| Command | Description |
|---|---|
| `cachyos-shelly-update` | list, ask and update |
| `cachyos-shelly-update -l` | only list |
| `cachyos-shelly-update -y` | update without asking |
| `cachyos-shelly-update -c` | silent check (the one the timer uses) |
| `cachyos-shelly-update --tray` | start the tray icon |
| `--no-repo` `--no-aur` `--no-flatpak` `--no-appimage` `--no-appman` `--no-devel` | skip sources |

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
src/cachyos-shelly-update          main script (bash)
src/cachyos-shelly-update-tray.py  tray icon (PyQt6)
data/                              .desktop files, systemd units, pacman hook, config example
tests/                             tests run by CI (they don't touch the system)
docs/pt-BR/                        Portuguese documentation
```

## Tests and CI

The GitLab pipeline runs on every merge request and every push to `main`:

- **lint**: `shellcheck` on the bash scripts, `ruff` on the Python (rules in `ruff.toml`), and validation of the `.desktop` files and the systemd units.
- **test**: `tests/smoke.sh` runs the real updater against fake `shelly` and `appman` commands, with a temporary HOME and no sudo, including AppMan apps built from each template layout. `tests/tray_smoke.py` builds the tray and its menu without a display.

To run them locally:

```bash
shellcheck install.sh src/cachyos-shelly-update tests/smoke.sh
bash tests/smoke.sh
ruff check .
pip install -r requirements.txt
QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
```

## Installed files

| Path | Contents |
|---|---|
| `/opt/cachyos-shelly-update/` | the program, `install.sh`, `VERSION`, `REPO`, the `.venv` virtualenv |
| `/usr/local/bin/cachyos-shelly-update` | link to the command |
| `/usr/local/share/applications/cachyos-shelly-update.desktop` | app menu entry |
| `/etc/xdg/autostart/cachyos-shelly-update-tray.desktop` | tray at session start |
| `/etc/systemd/user/cachyos-shelly-update.{service,timer}` | automatic checks |
| `/etc/pacman.d/hooks/cachyos-shelly-update-venv.hook` | rebuilds the virtualenv after Python upgrades |
| `~/.local/bin/appman` | AppMan, if the installer downloaded it |
| `~/.local/state/cachyos-shelly-update/` | state (updates per source, current icon) |

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).
