#!/usr/bin/env bash
#
# cachyos-shelly-update installer
#
#   ./install.sh install     install into /opt/cachyos-shelly-update (plus dependencies)
#   ./install.sh update      update from the git repository
#   ./install.sh uninstall   remove it (see --purge)
#   ./install.sh status      show what is installed
#
# Options:  -y | --yes   don't ask anything (pacman/yay get --noconfirm)
#           --purge      (uninstall) also delete the user's state and config, and
#                        offer to remove the packages and AppMan this installer added
#
# Run it as your normal user: it asks for sudo when needed.
# (yay and AppMan refuse to run as root.)
#
# Once installed, this script lives in /opt/cachyos-shelly-update/install.sh,
# so the repository can be deleted: update and uninstall work from there.

set -euo pipefail

# ---------- constants ----------
readonly APP_NAME=cachyos-shelly-update
readonly PREFIX=/opt/$APP_NAME
readonly BIN_LINK=/usr/local/bin/$APP_NAME
readonly APPLICATIONS_DIR=/usr/local/share/applications
readonly AUTOSTART_DIR=/etc/xdg/autostart
readonly USER_UNIT_DIR=/etc/systemd/user
readonly PACMAN_HOOK=/etc/pacman.d/hooks/$APP_NAME-venv.hook
# The tray's Python dependencies (PyQt6) live here, not in the system
readonly VENV_DIR=$PREFIX/.venv
# Packages this installer added, so --purge can offer to remove them
readonly INSTALLED_PACKAGES_FILE=$PREFIX/installed-packages
# Set when this installer downloaded AppMan (holds its path)
readonly INSTALLED_APPMAN_FILE=$PREFIX/installed-appman
readonly APPMAN_URL=https://raw.githubusercontent.com/ivan-hc/AM/main/APP-MANAGER
SOURCE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SOURCE_DIR

# dependency | repository package | AUR package (for yay) | required or optional
# "pacman -T" also accepts packages that provide the dependency (e.g. shelly-bin).
# The optional ones are tools AppMan uses to unpack apps; without them it
# stops to ask whether to download static copies.
readonly DEPENDENCIES=(
    "shelly|shelly|shelly-bin|required"
    "shelly-flatpak-backend|shelly-flatpak-backend|shelly-flatpak-backend-bin|required"
    "flatpak|flatpak||required"
    "python|python||required"
    "pacman-contrib|pacman-contrib||required"
    "libnotify|libnotify||required"
    "curl|curl||required"
    "wget|wget||optional"
    "unzip|unzip||optional"
    "7zip|7zip||optional"
    "binutils|binutils||optional"
    "file|file||optional"
    "xz|xz||optional"
)

# ---------- output ----------
if [[ -t 1 ]]; then
    readonly BOLD=$'\e[1m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
    readonly BOLD='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi
printInfo()    { printf '%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
printStep()    { printf '%s  ->%s %s\n' "$CYAN" "$RESET" "$*"; }
printWarning() { printf '%s==> WARNING:%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()          { printf '%s==> ERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Print the comment block at the top of this file, without the leading "# "
showHelp() {
    awk 'NR > 2 && !/^#/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"
}

# ---------- user / privileges ----------
assumeYes=0
purge=0
forwardedArgs=()
newlyInstalledPackages=()
if ((EUID == 0)); then
    SUDO_COMMAND=()
    TARGET_USER="${SUDO_USER:-}"
else
    SUDO_COMMAND=(sudo)
    TARGET_USER="${USER:-$(id -un)}"
fi
readonly SUDO_COMMAND TARGET_USER
asRoot() { "${SUDO_COMMAND[@]}" "$@"; }

TARGET_UID=""
TARGET_HOME=""
if [[ -n $TARGET_USER && $TARGET_USER != root ]]; then
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi
readonly TARGET_UID TARGET_HOME

# Run a command as the normal user, with access to their systemd --user
asUser() {
    [[ -n $TARGET_UID ]] || return 1
    if ((EUID == 0)); then
        sudo -u "$TARGET_USER" \
            HOME="$TARGET_HOME" \
            XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

# confirm "question" [default Y|N]
confirm() {
    ((assumeYes)) && return 0
    local answer defaultAnswer="${2:-Y}"
    read -rp "$(printf '%s::%s %s [%s] ' "$CYAN$BOLD" "$RESET" "$1" "$([[ $defaultAnswer == Y ]] && echo Y/n || echo y/N)")" answer
    answer="${answer,,}"
    [[ -z $answer ]] && answer="${defaultAnswer,,}"
    [[ $answer == y || $answer == yes ]]
}

# ---------- dependencies ----------
isSatisfied()  { pacman -T "$1" >/dev/null 2>&1; }
isInRepos()    { [[ -n $1 ]] && pacman -Si "$1" >/dev/null 2>&1; }
hasYay()       { command -v yay >/dev/null 2>&1; }

ensureDependencies() {
    printInfo "Checking dependencies"
    local entry dependency repoPackage aurPackage requirement noConfirm=()
    ((assumeYes)) && noConfirm=(--noconfirm)
    if hasYay; then
        printStep "yay found: $(yay --version 2>/dev/null | head -1)"
    else
        printStep "yay not found (only the official repositories will be used)"
    fi

    for entry in "${DEPENDENCIES[@]}"; do
        IFS='|' read -r dependency repoPackage aurPackage requirement <<<"$entry"
        if isSatisfied "$dependency"; then
            printStep "$dependency: ${GREEN}ok${RESET}"
            continue
        fi
        if isInRepos "$repoPackage"; then
            printStep "$dependency: installing with pacman"
            if asRoot pacman -S --needed "${noConfirm[@]}" "$repoPackage"; then
                newlyInstalledPackages+=("$repoPackage")
                continue
            fi
        elif [[ -n $aurPackage ]] && hasYay; then
            [[ -n $TARGET_UID ]] || die "$dependency needs yay, which doesn't run as root. Run this script as your user."
            printStep "$dependency: not in the repositories; installing $aurPackage with yay (AUR)"
            if asUser yay -S --needed "${noConfirm[@]}" "$aurPackage"; then
                newlyInstalledPackages+=("$aurPackage")
                continue
            fi
        fi
        if [[ $requirement == optional ]]; then
            printWarning "$dependency could not be installed (optional, used by AppMan)."
        else
            die "Could not install $dependency${aurPackage:+ (repositories or $aurPackage from the AUR with yay)}."
        fi
    done
}

# Remember every package we installed, across reinstalls
recordInstalledPackages() {
    ((${#newlyInstalledPackages[@]})) || return 0
    {
        cat "$INSTALLED_PACKAGES_FILE" 2>/dev/null || true
        printf '%s\n' "${newlyInstalledPackages[@]}"
    } | sort -u | asRoot tee "$INSTALLED_PACKAGES_FILE.tmp" >/dev/null
    asRoot mv -f "$INSTALLED_PACKAGES_FILE.tmp" "$INSTALLED_PACKAGES_FILE"
}

# ---------- AppMan ----------
userBinDir() {
    if ((EUID == 0)); then echo "$TARGET_HOME/.local/bin"; else echo "${XDG_BIN_HOME:-$HOME/.local/bin}"; fi
}

findAppman() {
    local candidate
    for candidate in "$(asUser bash -c 'command -v appman' 2>/dev/null || true)" "$(userBinDir)/appman"; do
        if [[ -n $candidate && -x $candidate ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# AppMan has no package: its official installer just downloads the
# APP-MANAGER script as ~/.local/bin/appman, which is what we do here.
# It is not configured: the first "appman -i <app>" asks where to keep apps.
ensureAppman() {
    printInfo "Checking AppMan"
    local appmanPath binDir downloadFile
    if appmanPath="$(findAppman)"; then
        printStep "appman: ${GREEN}ok${RESET} ($appmanPath)"
        return 0
    fi
    if [[ -z $TARGET_UID ]]; then
        printWarning "AppMan is per user and can't be installed for root. Run this script as your user to get it."
        return 0
    fi
    binDir="$(userBinDir)"
    downloadFile="$(asUser mktemp)"
    printStep "appman: downloading to $binDir/appman"
    if ! asUser curl -fsSL "$APPMAN_URL" -o "$downloadFile" || ! grep -q '^AMVERSION=' "$downloadFile"; then
        asUser rm -f "$downloadFile"
        printWarning "Could not download AppMan; AppMan apps won't be updated."
        return 0
    fi
    asUser install -Dm755 "$downloadFile" "$binDir/appman"
    asUser rm -f "$downloadFile"
    printf '%s\n' "$binDir/appman" | asRoot tee "$INSTALLED_APPMAN_FILE" >/dev/null
    printStep "appman: ${GREEN}installed${RESET} (run 'appman -h' to get started)"
}

# ---------- Python virtualenv for the tray ----------
pythonVersion() { "$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null; }

# Builds $VENV_DIR when it is missing, when requirements.txt changed, or when
# the system Python moved to a new minor version (which breaks a venv).
ensureVenv() {
    local requirementsFile="$1" wantedHash wantedPython builtHash builtPython
    wantedHash="$(sha256sum "$requirementsFile" | cut -d' ' -f1)"
    wantedPython="$(pythonVersion python3)" || die "python3 not found."
    builtHash="$(cat "$VENV_DIR/.requirements.sha256" 2>/dev/null || true)"
    builtPython="$(pythonVersion "$VENV_DIR/bin/python" || true)"
    if [[ $builtHash == "$wantedHash" && $builtPython == "$wantedPython" ]]; then
        printStep "tray virtualenv: ${GREEN}ok${RESET} (Python $builtPython)"
        return 0
    fi
    printStep "tray virtualenv: building with Python $wantedPython (downloads PyQt6)"
    asRoot rm -rf "$VENV_DIR"
    asRoot python3 -m venv "$VENV_DIR"
    asRoot env PIP_ROOT_USER_ACTION=ignore "$VENV_DIR/bin/pip" install --quiet \
        --disable-pip-version-check --no-cache-dir --only-binary=:all: -r "$requirementsFile" \
        || die "Could not install the tray dependencies into $VENV_DIR."
    printf '%s\n' "$wantedHash" | asRoot tee "$VENV_DIR/.requirements.sha256" >/dev/null
}

# ---------- files ----------
installFiles() {
    printInfo "Installing into $PREFIX"
    [[ -f $SOURCE_DIR/src/$APP_NAME ]] || die "Project files not found in $SOURCE_DIR/src (run install from the repository)."

    asRoot install -Dm755 "$SOURCE_DIR/src/$APP_NAME"                "$PREFIX/bin/$APP_NAME"
    asRoot install -Dm755 "$SOURCE_DIR/src/$APP_NAME-tray.py"        "$PREFIX/lib/$APP_NAME-tray.py"
    asRoot install -Dm644 "$SOURCE_DIR/VERSION"                      "$PREFIX/VERSION"
    asRoot install -Dm644 "$SOURCE_DIR/requirements.txt"             "$PREFIX/requirements.txt"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME.conf.example"  "$PREFIX/$APP_NAME.conf.example"
    [[ $SOURCE_DIR == "$PREFIX" ]] || asRoot install -Dm755 "$SOURCE_DIR/install.sh" "$PREFIX/install.sh"

    # Remember where we came from, so "update" works without the repository
    local repoUrl="${CACHYOS_SHELLY_UPDATE_REPO:-}"
    [[ -z $repoUrl && -d $SOURCE_DIR/.git ]] && repoUrl="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -n $repoUrl ]]; then
        printf '%s\n' "$repoUrl" | asRoot tee "$PREFIX/REPO" >/dev/null
        printStep "update source: $repoUrl"
    fi

    ensureVenv "$PREFIX/requirements.txt"

    asRoot ln -sfn "$PREFIX/bin/$APP_NAME" "$BIN_LINK"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME.desktop"       "$APPLICATIONS_DIR/$APP_NAME.desktop"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME-tray.desktop"  "$AUTOSTART_DIR/$APP_NAME-tray.desktop"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME.service"       "$USER_UNIT_DIR/$APP_NAME.service"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME.timer"         "$USER_UNIT_DIR/$APP_NAME.timer"
    asRoot install -Dm644 "$SOURCE_DIR/data/$APP_NAME-venv.hook"     "$PACMAN_HOOK"
    printStep "command: $BIN_LINK"
    printStep "app menu entry, tray autostart, systemd timer and pacman hook installed"
}

enableServices() {
    printInfo "Enabling the automatic check and the tray"
    # Timer for every user (the same thing cachy-update does)
    asRoot systemctl --global enable "$APP_NAME.timer" >/dev/null 2>&1 || printWarning "could not enable the timer globally"

    if asUser systemctl --user daemon-reload 2>/dev/null; then
        asUser systemctl --user restart "$APP_NAME.timer" 2>/dev/null && printStep "timer started"
        # A first check in the background so the tray has data right away
        asUser systemctl --user start --no-block "$APP_NAME.service" 2>/dev/null || true
    else
        printWarning "No user session found; the timer starts at the next login."
    fi

    # (Re)start the tray in the current graphical session
    if ((EUID != 0)) && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
        pkill -u "$USER" -f "$APP_NAME-tray.py" 2>/dev/null || true
        sleep 0.5
        setsid "$BIN_LINK" --tray >/dev/null 2>&1 < /dev/null &
        printStep "tray started"
    else
        printStep "the tray appears at the next login"
    fi
}

checkIcons() {
    if [[ ! -e /usr/share/icons/hicolor/scalable/apps/cachy-update-blue.svg ]]; then
        printWarning "cachy-update icons not found; the tray will use generic theme icons."
        printWarning "To get the same icons: sudo pacman -S cachy-update"
    fi
}

offerToDisableCachyUpdate() {
    local isActive=0
    asUser systemctl --user is-enabled arch-update.timer >/dev/null 2>&1 && isActive=1
    asUser systemctl --user is-enabled arch-update-tray.service >/dev/null 2>&1 && isActive=1
    pgrep -f arch-update-tray >/dev/null 2>&1 && isActive=1
    ((isActive)) || return 0

    echo
    printWarning "cachy-update is also active (you would get two icons and two checks)."
    if confirm "Disable cachy-update's timer and tray? (the package stays installed)" Y; then
        asRoot systemctl --global disable arch-update.timer arch-update-tray.service >/dev/null 2>&1 || true
        asUser systemctl --user disable --now arch-update.timer arch-update-tray.service >/dev/null 2>&1 || true
        [[ -n $TARGET_HOME ]] && rm -f "$TARGET_HOME"/.config/autostart/{arch,cachy}-update-tray.desktop
        pkill -f arch-update-tray 2>/dev/null || true
        printStep "cachy-update disabled (turn it back on in CachyOS Hello whenever you want)"
    fi
}

# ---------- commands ----------
cmdInstall() {
    command -v pacman >/dev/null || die "This installer is for Arch/CachyOS (pacman not found)."
    local installedVersion=""
    [[ -f $PREFIX/VERSION ]] && installedVersion="$(cat "$PREFIX/VERSION")"
    printInfo "$APP_NAME $(cat "$SOURCE_DIR/VERSION")${installedVersion:+ (installed: $installedVersion)}"

    ((EUID != 0)) && { sudo -v || die "sudo is required"; }
    ensureDependencies
    asRoot mkdir -p "$PREFIX"
    recordInstalledPackages
    installFiles
    ensureAppman
    enableServices
    checkIcons
    offerToDisableCachyUpdate

    echo
    printInfo "Done! Run '$APP_NAME' in a terminal or click the tray icon."
    echo "   Update:  $PREFIX/install.sh update"
    echo "   Remove:  $PREFIX/install.sh uninstall"
}

cmdUpdate() {
    command -v git >/dev/null || die "git not found."
    ((EUID != 0)) && { sudo -v || die "sudo is required"; }

    # 1) Running from a clone of the repository: git pull and reinstall
    if [[ $SOURCE_DIR != "$PREFIX" && -d $SOURCE_DIR/.git ]]; then
        printInfo "Updating the repository in $SOURCE_DIR"
        if [[ -n $TARGET_UID ]]; then
            asUser git -C "$SOURCE_DIR" pull --ff-only || die "git pull failed"
        else
            git -C "$SOURCE_DIR" pull --ff-only || die "git pull failed"
        fi
        exec bash "$SOURCE_DIR/install.sh" install "${forwardedArgs[@]}"
    fi

    # 2) Running from /opt: fetch the new version from the saved repository
    local repoUrl="${CACHYOS_SHELLY_UPDATE_REPO:-$(cat "$PREFIX/REPO" 2>/dev/null || true)}"
    [[ -n $repoUrl ]] || die "Don't know where to update from. Run: CACHYOS_SHELLY_UPDATE_REPO=<git-url> $0 update"

    # Global (not local) so the EXIT trap still sees it when the script ends
    UPDATE_TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$UPDATE_TEMP_DIR"' EXIT
    chmod 755 "$UPDATE_TEMP_DIR"
    if [[ -n $TARGET_UID ]]; then
        chown "$TARGET_USER" "$UPDATE_TEMP_DIR" 2>/dev/null || true
    fi

    printInfo "Downloading $repoUrl"
    # Clone as the user (uses their SSH keys/credentials)
    asUser git clone --quiet --depth 1 "$repoUrl" "$UPDATE_TEMP_DIR/repo" 2>/dev/null \
        || git clone --quiet --depth 1 "$repoUrl" "$UPDATE_TEMP_DIR/repo" \
        || die "Could not clone $repoUrl"

    local installedVersion newVersion
    installedVersion="$(cat "$PREFIX/VERSION" 2>/dev/null || echo 0)"
    newVersion="$(cat "$UPDATE_TEMP_DIR/repo/VERSION")"
    if [[ $installedVersion == "$newVersion" ]] && ! confirm "Already at version $installedVersion. Reinstall anyway?" N; then
        printInfo "Nothing to do."
        exit 0
    fi
    CACHYOS_SHELLY_UPDATE_REPO="$repoUrl" bash "$UPDATE_TEMP_DIR/repo/install.sh" install "${forwardedArgs[@]}"
}

# Called by the pacman hook after python is upgraded (runs as root, no prompts)
cmdRebuildVenv() {
    ((EUID == 0)) || die "rebuild-venv is run by pacman as root."
    [[ -f $PREFIX/requirements.txt ]] || exit 0
    # A subshell, so a failure (e.g. no network) warns instead of failing pacman's hook
    (ensureVenv "$PREFIX/requirements.txt") || printWarning "Run '$PREFIX/install.sh update' to repair the tray."
}

cmdUninstall() {
    printInfo "Removing $APP_NAME"
    ((EUID != 0)) && { sudo -v || die "sudo is required"; }

    # Read what we installed before $PREFIX is gone
    local addedPackages=() addedAppman=""
    [[ -f $INSTALLED_PACKAGES_FILE ]] && mapfile -t addedPackages < "$INSTALLED_PACKAGES_FILE"
    [[ -f $INSTALLED_APPMAN_FILE ]] && addedAppman="$(cat "$INSTALLED_APPMAN_FILE")"

    if [[ -n $TARGET_USER ]]; then
        pkill -u "$TARGET_USER" -f "$APP_NAME-tray.py" 2>/dev/null || true
        asUser systemctl --user disable --now "$APP_NAME.timer" >/dev/null 2>&1 || true
    fi
    asRoot systemctl --global disable "$APP_NAME.timer" >/dev/null 2>&1 || true

    asRoot rm -f "$BIN_LINK" "$APPLICATIONS_DIR/$APP_NAME.desktop" "$AUTOSTART_DIR/$APP_NAME-tray.desktop" \
                 "$USER_UNIT_DIR/$APP_NAME.service" "$USER_UNIT_DIR/$APP_NAME.timer" "$PACMAN_HOOK"
    # $PREFIX holds the tray virtualenv too, so this removes PyQt6 as well
    asRoot rm -rf "$PREFIX"
    asUser systemctl --user daemon-reload >/dev/null 2>&1 || true
    printStep "files removed (including the tray virtualenv)"

    if ((purge)); then
        if [[ -n $TARGET_HOME ]]; then
            rm -rf "$TARGET_HOME/.local/state/$APP_NAME" "$TARGET_HOME/.config/$APP_NAME"
            printStep "user state and config deleted"
        fi
        removeAddedPackages "${addedPackages[@]}"
        removeAddedAppman "$addedAppman"
    elif ((${#addedPackages[@]})) || [[ -n $addedAppman ]]; then
        echo "   Dependencies added by the installer were kept. Run with --purge to remove them too."
    fi

    echo
    printInfo "$APP_NAME removed."
    echo "   To go back to cachy-update: CachyOS Hello > Apps/Tweaks > Cachy Update"
}

# Offer to remove the packages the installer added (only those still installed)
removeAddedPackages() {
    local package stillInstalled=()
    for package in "$@"; do
        pacman -Q "$package" >/dev/null 2>&1 && stillInstalled+=("$package")
    done
    ((${#stillInstalled[@]})) || return 0
    echo
    printInfo "Packages installed by $APP_NAME: ${stillInstalled[*]}"
    confirm "Remove them? (each one is kept if something else still needs it)" N || return 0
    for package in "${stillInstalled[@]}"; do
        if asRoot pacman -Rns --noconfirm "$package" >/dev/null 2>&1; then
            printStep "$package removed"
        else
            printStep "$package kept (required by another package)"
        fi
    done
}

# Offer to remove AppMan if the installer downloaded it. Apps installed
# with AppMan are left alone: they are the user's.
removeAddedAppman() {
    local appmanPath="$1"
    [[ -n $appmanPath && -f $appmanPath ]] || return 0
    echo
    printInfo "AppMan was installed by $APP_NAME ($appmanPath)."
    confirm "Remove AppMan? (apps you installed with it are kept)" N || return 0
    rm -f "$appmanPath"
    printStep "AppMan removed"
}

cmdStatus() {
    local installedVersion="not installed"
    [[ -f $PREFIX/VERSION ]] && installedVersion="$(cat "$PREFIX/VERSION")"
    printInfo "$APP_NAME: $installedVersion"
    [[ -f $PREFIX/REPO ]] && printStep "source: $(cat "$PREFIX/REPO")"

    printInfo "Dependencies"
    local entry dependency repoPackage aurPackage requirement appmanPath
    for entry in "${DEPENDENCIES[@]}"; do
        IFS='|' read -r dependency repoPackage aurPackage requirement <<<"$entry"
        if isSatisfied "$dependency"; then
            printStep "$dependency: ${GREEN}ok${RESET}"
        else
            printStep "$dependency: ${RED}missing${RESET} ($requirement)"
        fi
    done
    if hasYay; then printStep "yay: ${GREEN}ok${RESET}"; else printStep "yay: not installed"; fi
    if appmanPath="$(findAppman)"; then printStep "appman: ${GREEN}ok${RESET} ($appmanPath)"; else printStep "appman: not installed"; fi
    if "$VENV_DIR/bin/python" -c 'import PyQt6' 2>/dev/null; then
        printStep "tray virtualenv: ${GREEN}ok${RESET}"
    else
        printStep "tray virtualenv: ${RED}broken or missing${RESET} (run: $PREFIX/install.sh update)"
    fi

    printInfo "Services"
    printStep "timer: $(asUser systemctl --user is-active "$APP_NAME.timer" 2>/dev/null || echo inactive)"
    if pgrep -f "$APP_NAME-tray.py" >/dev/null; then printStep "tray: running"; else printStep "tray: stopped"; fi
}

# ---------- main ----------
main() {
    local command=""
    while (($#)); do
        case "$1" in
            install|update|uninstall|status|rebuild-venv) command="$1" ;;
            -y|--yes)  assumeYes=1; forwardedArgs+=(-y) ;;
            --purge)   purge=1 ;;
            -h|--help) showHelp; exit 0 ;;
            *) die "Unknown option: $1 (see $0 --help)" ;;
        esac
        shift
    done
    case "$command" in
        install)      cmdInstall ;;
        update)       cmdUpdate ;;
        uninstall)    cmdUninstall ;;
        status)       cmdStatus ;;
        rebuild-venv) cmdRebuildVenv ;;
        *) showHelp; exit 1 ;;
    esac
}

# Everything runs inside main: bash reads the whole function before running
# it, so uninstall can delete this very file safely
main "$@"
exit
