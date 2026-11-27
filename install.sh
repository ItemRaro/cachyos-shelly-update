#!/usr/bin/env bash
#
# cachyos-shelly-update installer
#
#   ./install.sh install     install into /opt/cachyos-shelly-update (plus dependencies)
#   ./install.sh update      update from the git repository
#   ./install.sh sources     pick again what it updates (repositories, AUR,
#                            Flatpak, AppImage, AppMan)
#   ./install.sh uninstall   remove it (see --purge)
#   ./install.sh status      show what is installed
#
# Options:  -y | --yes   don't ask anything: every source not turned down
#                        before is picked and its tools installed, and
#                        pacman/yay get --noconfirm
#           --purge      (uninstall) also delete the user's state and config, and
#                        offer to remove the packages and AppMan this installer added
#
# Run it as your normal user: it asks for sudo when needed.
# (yay and AppMan refuse to run as root.)
#
# Once installed, this script lives in /opt/cachyos-shelly-update/install.sh,
# so the repository can be deleted: update and uninstall work from there.
#
# Self-update contract (tests/self_update.sh checks it against every release):
# "update" from /opt is run by the INSTALLED (older) install.sh, which clones
# the repository and runs the NEW one as
#   CACHYOS_SHELLY_UPDATE_REPO=<url> bash <clone>/install.sh install [-y]
# so "install" must keep accepting that, and must turn any older layout into
# exactly what a fresh install gives: stale files removed (installed-files),
# the venv rebuilt when requirements.txt or Python changed, bytecode
# recompiled, units reloaded, the running tray restarted on the new code,
# and the state in $PREFIX and ~/.local/state kept.

set -euo pipefail

# ---------- constants ----------
readonly APP_NAME=cachyos-shelly-update
readonly PREFIX=/opt/$APP_NAME
readonly BIN_LINK=/usr/local/bin/$APP_NAME
readonly APPLICATIONS_DIR=/usr/local/share/applications
readonly AUTOSTART_DIR=/etc/xdg/autostart
readonly USER_UNIT_DIR=/etc/systemd/user
readonly PACMAN_HOOK=/etc/pacman.d/hooks/$APP_NAME-venv.hook
# The project's Python: the CLI runs on it (falling back to the system
# python3 if it is broken) and the tray's dependencies (PyQt6) live in it
readonly VENV_DIR=$PREFIX/.venv
# The Python package (CLI + tray) is installed here
readonly LIB_DIR=$PREFIX/lib
# Matches our tray process: 2.x runs "-m shellyupdate.tray", 1.x ran the .py file
readonly TRAY_PROCESS_PATTERN="shellyupdate\\.tray|$APP_NAME-tray\\.py"
# Packages this installer added, so --purge can offer to remove them
readonly INSTALLED_PACKAGES_FILE=$PREFIX/installed-packages
# Set when this installer downloaded AppMan (holds its path)
readonly INSTALLED_APPMAN_FILE=$PREFIX/installed-appman
readonly APPMAN_URL=https://raw.githubusercontent.com/ivan-hc/AM/main/APP-MANAGER
# Optional tools the user said no to, so a reinstall/update doesn't ask again
readonly DECLINED_TOOLS_FILE=$PREFIX/declined-tools
# The update sources picked (one key per line); the updater only checks,
# updates and cleans these
readonly SOURCES_FILE=$PREFIX/sources
readonly SOURCE_KEYS=(repo aur flatpak appimage appman)
# Every file installFiles put in place (a trailing / marks a directory it
# owns), so an update removes what the new version no longer installs
readonly MANIFEST_FILE=$PREFIX/installed-files
readonly FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
readonly YAY_AUR_URL=https://aur.archlinux.org/yay-bin.git
SOURCE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SOURCE_DIR

# dependency | repository package | AUR package (for an AUR helper) | required or optional
# "pacman -T" also accepts packages that provide the dependency (e.g. shelly-bin).
# The optional ones are tools AppMan uses to unpack apps; without them it
# stops to ask whether to download static copies.
# Flatpak, an AUR helper and AppMan are asked about separately (see
# "optional tools"): the updater skips whatever isn't there.
readonly DEPENDENCIES=(
    "shelly|shelly|shelly-bin|required"
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
    # printf, not "read -p": read only shows its prompt when stdin is a terminal
    printf '%s::%s %s [%s] ' "$CYAN$BOLD" "$RESET" "$1" "$([[ $defaultAnswer == Y ]] && echo Y/n || echo y/N)"
    read -r answer || answer=""
    [[ -t 0 ]] || echo
    answer="${answer,,}"
    [[ -z $answer ]] && answer="${defaultAnswer,,}"
    [[ $answer == y || $answer == yes ]]
}

# ---------- dependencies ----------
isSatisfied()  { pacman -T "$1" >/dev/null 2>&1; }
isInRepos()    { [[ -n $1 ]] && pacman -Si "$1" >/dev/null 2>&1; }
# The installed AUR helper (yay or paru), if any
aurHelper() {
    local helper
    for helper in yay paru; do
        command -v "$helper" >/dev/null 2>&1 && { echo "$helper"; return 0; }
    done
    return 1
}
noConfirmArgs() { ((assumeYes)) && echo --noconfirm; return 0; }

# installPackage <dependency> <repository package> [AUR package]: from the
# repositories first, the AUR (through yay/paru) otherwise. Records what it added.
installPackage() {
    local dependency=$1 repoPackage=$2 aurPackage=${3:-} helper noConfirm=()
    mapfile -t noConfirm < <(noConfirmArgs)
    isSatisfied "$dependency" && return 0
    if isInRepos "$repoPackage"; then
        printStep "$dependency: installing with pacman"
        asRoot pacman -S --needed "${noConfirm[@]}" "$repoPackage" || return 1
        newlyInstalledPackages+=("$repoPackage")
        return 0
    fi
    if [[ -n $aurPackage ]] && helper="$(aurHelper)" && [[ -n $TARGET_UID ]]; then
        printStep "$dependency: not in the repositories; installing $aurPackage with $helper (AUR)"
        asUser "$helper" -S --needed "${noConfirm[@]}" "$aurPackage" || return 1
        newlyInstalledPackages+=("$aurPackage")
        return 0
    fi
    return 1
}

ensureDependencies() {
    printInfo "Checking dependencies"
    local entry dependency repoPackage aurPackage requirement
    for entry in "${DEPENDENCIES[@]}"; do
        IFS='|' read -r dependency repoPackage aurPackage requirement <<<"$entry"
        if isSatisfied "$dependency"; then
            printStep "$dependency: ${GREEN}ok${RESET}"
        elif ! installPackage "$dependency" "$repoPackage" "$aurPackage"; then
            if [[ $requirement == optional ]]; then
                printWarning "$dependency could not be installed (optional, used by AppMan)."
            else
                die "Could not install $dependency${aurPackage:+ (repositories, or $aurPackage from the AUR with yay/paru)}."
            fi
        fi
    done
}

# ---------- optional tools ----------
# Asked about once; a "no" is remembered until uninstall, so updates don't
# ask again. With -y everything is installed.
wasDeclined() { grep -qxF "$1" "$DECLINED_TOOLS_FILE" 2>/dev/null; }
recordDeclined() {
    printf '%s\n' "$1" | asRoot tee -a "$DECLINED_TOOLS_FILE" >/dev/null
    printStep "skipped (run '$PREFIX/install.sh install' again after deleting $DECLINED_TOOLS_FILE to be asked again)"
}
# offerTool <key> "<question>": true when the user wants it
offerTool() {
    wasDeclined "$1" && return 1
    echo
    if confirm "$2" Y; then return 0; fi
    recordDeclined "$1"
    return 1
}
# Silent versions, for the source list's answers
rememberDeclined() {
    wasDeclined "$1" && return 0
    printf '%s\n' "$1" | asRoot tee -a "$DECLINED_TOOLS_FILE" >/dev/null
}
forgetDeclined() {
    wasDeclined "$1" || return 0
    { grep -vxF "$1" "$DECLINED_TOOLS_FILE" || true; } | asRoot tee "$DECLINED_TOOLS_FILE.tmp" >/dev/null
    asRoot mv -f "$DECLINED_TOOLS_FILE.tmp" "$DECLINED_TOOLS_FILE"
}

# yay: from the repositories when it's there (CachyOS has it), otherwise
# built from the AUR (yay-bin) as the user, the way yay's README does it
offerAurHelper() {
    local helper buildDir
    if helper="$(aurHelper)"; then
        printStep "AUR helper: ${GREEN}$helper${RESET}"
        return 0
    fi
    offerTool yay "No AUR helper found. Install yay (installs AUR packages Shelly needs that aren't in the repositories)?" || return 0
    if installPackage yay yay; then
        printStep "yay: ${GREEN}installed${RESET}"
        return 0
    fi
    [[ -n $TARGET_UID ]] || { printWarning "yay is built as a normal user; run this script as your user."; return 0; }
    installPackage git git || { printWarning "git is needed to build yay"; return 0; }
    installPackage base-devel base-devel || { printWarning "base-devel is needed to build yay"; return 0; }
    buildDir="$(asUser mktemp -d)"
    printStep "yay: building yay-bin from the AUR"
    if asUser git clone --quiet --depth 1 "$YAY_AUR_URL" "$buildDir/yay-bin" \
        && (cd "$buildDir/yay-bin" && asUser makepkg -si --needed --noconfirm); then
        newlyInstalledPackages+=(yay-bin)
        printStep "yay: ${GREEN}installed${RESET}"
    else
        printWarning "could not build yay; AUR packages will only come from Shelly"
    fi
    asUser rm -rf "$buildDir"
}

hasFlathub() { flatpak remotes --columns=name 2>/dev/null | grep -qx flathub; }

# Flatpak, Shelly's Flatpak backend (Shelly updates Flatpak apps through it)
# and the Flathub remote
offerFlatpak() {
    if ! isSatisfied flatpak; then
        offerTool flatpak "Flatpak isn't installed. Install it, with Shelly's Flatpak backend and Flathub?" || return 0
        installPackage flatpak flatpak || { printWarning "could not install flatpak"; return 0; }
        installPackage shelly-flatpak-backend shelly-flatpak-backend shelly-flatpak-backend-bin \
            || printWarning "could not install shelly-flatpak-backend; Shelly won't update Flatpak apps"
        addFlathub
        return 0
    fi
    printStep "flatpak: ${GREEN}ok${RESET}"
    if ! isSatisfied shelly-flatpak-backend \
        && offerTool flatpak-backend "Shelly's Flatpak backend is missing (Shelly needs it to update Flatpak apps). Install it?"; then
        installPackage shelly-flatpak-backend shelly-flatpak-backend shelly-flatpak-backend-bin \
            || printWarning "could not install shelly-flatpak-backend"
    fi
    if hasFlathub; then
        printStep "flathub: ${GREEN}ok${RESET}"
    elif offerTool flathub "Flatpak has no Flathub remote. Add Flathub?"; then
        addFlathub
    fi
}

addFlathub() {
    hasFlathub && return 0
    if asRoot flatpak remote-add --if-not-exists flathub "$FLATHUB_URL"; then
        printStep "flathub: ${GREEN}added${RESET}"
    else
        printWarning "could not add Flathub"
    fi
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
offerAppman() {
    local appmanPath binDir downloadFile
    if appmanPath="$(findAppman)"; then
        printStep "appman: ${GREEN}ok${RESET} ($appmanPath)"
        return 0
    fi
    offerTool appman "AppMan isn't installed. Install it (installs and updates AppImages, updated here too)?" || return 0
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

# ---------- update sources ----------
# Picked from a list like eemeeve.sh's (numbers toggle, Enter applies). A
# picked source whose tool is missing is offered for install; one left out
# is never used, even if its tool is installed. Saved in $SOURCES_FILE, so
# updates keep the choice; "install.sh sources" shows the list again.
pickedSources=()

sourceTitle() {
    case $1 in
        repo)     echo "Repositories (pacman packages)" ;;
        aur)      echo "AUR" ;;
        flatpak)  echo "Flatpak" ;;
        appimage) echo "AppImage (through Shelly)" ;;
        appman)   echo "AppMan apps" ;;
    esac
}

# The tool a source needs on top of Shelly, if it is missing
missingTool() {
    case $1 in
        flatpak) isSatisfied flatpak || echo "Flatpak" ;;
        appman)  findAppman >/dev/null || echo "AppMan" ;;
    esac
    return 0
}

isPicked() {
    local key
    for key in "${pickedSources[@]}"; do [[ $key == "$1" ]] && return 0; done
    return 1
}

# Without a saved choice: what is installed and wasn't turned down before;
# with -y also what isn't installed yet (it gets installed)
defaultSources() {
    local key
    for key in "${SOURCE_KEYS[@]}"; do
        wasDeclined "$key" && continue
        [[ -z $(missingTool "$key") ]] || ((assumeYes)) || continue
        echo "$key"
    done
}

readSavedSources() {
    local key
    pickedSources=()
    for key in "${SOURCE_KEYS[@]}"; do
        grep -qxF "$key" "$SOURCES_FILE" 2>/dev/null && pickedSources+=("$key")
    done
    return 0
}

# chooseSources [force]: the saved choice, or the list (always with force)
chooseSources() {
    local force=${1:-0} key answer number i missing
    if ((!force)) && [[ -s $SOURCES_FILE ]]; then
        readSavedSources
        if ((${#pickedSources[@]})); then
            for key in "${pickedSources[@]}"; do printStep "$(sourceTitle "$key")"; done
            printStep "change them with: $PREFIX/install.sh sources"
            return 0
        fi
    fi
    if ((force)) && [[ -s $SOURCES_FILE ]]; then
        readSavedSources
    else
        mapfile -t pickedSources < <(defaultSources)
    fi
    if ((assumeYes)); then
        for key in "${pickedSources[@]}"; do printStep "$(sourceTitle "$key")"; done
        return 0
    fi
    while true; do
        echo
        echo "What should $APP_NAME update? (toggle with the numbers, Enter to apply):"
        i=0
        for key in "${SOURCE_KEYS[@]}"; do
            i=$((i + 1))
            missing=$(missingTool "$key")
            if isPicked "$key"; then
                printf '  %d) %s[x]%s %s' "$i" "$GREEN" "$RESET" "$(sourceTitle "$key")"
            else
                printf '  %d) [ ] %s' "$i" "$(sourceTitle "$key")"
            fi
            [[ -n $missing ]] && printf ' %s(%s not installed: offered when picked)%s' "$YELLOW" "$missing" "$RESET"
            echo
        done
        printf '  > '
        # No terminal (EOF): keep what is shown
        local atEnd=0
        read -r answer || { atEnd=1; answer=""; }
        [[ -t 0 ]] || echo
        if [[ -z $answer ]]; then
            ((${#pickedSources[@]})) && break
            printWarning "Pick at least one source."
            mapfile -t pickedSources < <(defaultSources)
            if ((atEnd)); then
                ((${#pickedSources[@]})) || pickedSources=(repo)
                break
            fi
            continue
        fi
        for number in $answer; do
            [[ $number =~ ^[0-9]+$ ]] || continue
            ((number >= 1 && number <= ${#SOURCE_KEYS[@]})) || continue
            key=${SOURCE_KEYS[number - 1]}
            if isPicked "$key"; then
                local kept=() other
                for other in "${pickedSources[@]}"; do [[ $other == "$key" ]] || kept+=("$other"); done
                pickedSources=("${kept[@]}")
            else
                pickedSources+=("$key")
            fi
        done
    done
    # Remember the "no"s for the next fresh choice; a "yes" clears an old "no"
    for key in "${SOURCE_KEYS[@]}"; do
        if isPicked "$key"; then
            forgetDeclined "$key"
            # Flatpak picked: its backend and Flathub may be offered again too
            if [[ $key == flatpak ]]; then
                forgetDeclined flatpak-backend
                forgetDeclined flathub
            fi
        else
            rememberDeclined "$key"
        fi
    done
}

# Write the choice, without sources whose tool still isn't there
saveSources() {
    local key kept=() missing
    for key in "${SOURCE_KEYS[@]}"; do
        isPicked "$key" || continue
        missing=$(missingTool "$key")
        if [[ -n $missing ]]; then
            printWarning "$missing isn't installed: $(sourceTitle "$key") left out (pick it again with: $PREFIX/install.sh sources)"
            continue
        fi
        kept+=("$key")
    done
    pickedSources=("${kept[@]}")
    printf '%s\n' "${pickedSources[@]}" | asRoot tee "$SOURCES_FILE" >/dev/null
}

# Install the tools of the picked sources
offerSourceTools() {
    if isPicked flatpak; then
        printInfo "Checking Flatpak"
        offerFlatpak
    fi
    recordInstalledPackages
}
offerSourceUserTools() {
    if isPicked appman; then
        printInfo "Checking AppMan"
        offerAppman
    fi
    recordInstalledPackages
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
        printStep "virtualenv: ${GREEN}ok${RESET} (Python $builtPython)"
        return 0
    fi
    printStep "virtualenv: building with Python $wantedPython (downloads PyQt6)"
    asRoot rm -rf "$VENV_DIR"
    asRoot python3 -m venv "$VENV_DIR"
    asRoot env PIP_ROOT_USER_ACTION=ignore "$VENV_DIR/bin/pip" install --quiet \
        --disable-pip-version-check --no-cache-dir --only-binary=:all: -r "$requirementsFile" \
        || die "Could not install the tray dependencies into $VENV_DIR."
    printf '%s\n' "$wantedHash" | asRoot tee "$VENV_DIR/.requirements.sha256" >/dev/null
}

# ---------- files ----------
# Precompile the package: users can't write to /opt, so without this every
# run (the timer's too) would compile it again in memory. Bytecode for an
# older Python is dropped first; the pacman hook calls this after upgrades.
compileBytecode() {
    [[ -d $LIB_DIR/shellyupdate ]] || return 0
    asRoot rm -rf "$LIB_DIR/shellyupdate/__pycache__"
    asRoot python3 -m compileall -q "$LIB_DIR/shellyupdate" >/dev/null \
        || printWarning "could not precompile $LIB_DIR (it still works, just starts slower)"
}

installedFiles=()
# installFile <mode> <source> <target>: install one file, recorded in the manifest
installFile() {
    asRoot install -Dm"$1" "$2" "$3"
    installedFiles+=("$3")
}

# Is this manifest entry something only we would have installed? A guard
# against a damaged manifest: never anything outside $PREFIX that isn't
# named after us, in the directories we install into.
isOwnedPath() {
    local path=${1%/}
    [[ $path == /* && $path != *..* ]] || return 1
    [[ $path == "$PREFIX"/?* ]] && return 0
    case ${path%/*} in
        "${BIN_LINK%/*}"|"$APPLICATIONS_DIR"|"$AUTOSTART_DIR"|"$USER_UNIT_DIR"|"${PACMAN_HOOK%/*}")
            [[ ${path##*/} == "$APP_NAME"* ]] ;;
        *) return 1 ;;
    esac
}

# Remove what the previous install listed and this one no longer installs.
# Installs from before the manifest (up to 2.1.0) only had files this
# version installs too, so there is nothing to remove for them.
removeStaleFiles() {
    local previousFiles=() path
    [[ -f $MANIFEST_FILE ]] && mapfile -t previousFiles < "$MANIFEST_FILE"
    for path in "${previousFiles[@]}"; do
        [[ -n $path ]] || continue
        printf '%s\n' "${installedFiles[@]}" | grep -qxF -- "$path" && continue
        if ! isOwnedPath "$path"; then
            printWarning "left alone: $path (listed in $MANIFEST_FILE, but not one of ours)"
            continue
        fi
        asRoot rm -rf -- "${path%/}"
        printStep "removed (no longer used): $path"
    done
    printf '%s\n' "${installedFiles[@]}" | asRoot tee "$MANIFEST_FILE" >/dev/null
}

installFiles() {
    printInfo "Installing into $PREFIX"
    [[ -f $SOURCE_DIR/src/$APP_NAME ]] || die "Project files not found in $SOURCE_DIR/src (run install from the repository)."
    installedFiles=()

    installFile 755 "$SOURCE_DIR/src/$APP_NAME"                "$PREFIX/bin/$APP_NAME"
    # A clean package directory: drops modules and bytecode of older versions,
    # and 1.x's single tray file
    asRoot rm -rf "$LIB_DIR"
    asRoot install -Dm644 -t "$LIB_DIR/shellyupdate" "$SOURCE_DIR"/src/shellyupdate/*.py
    installedFiles+=("$LIB_DIR/")
    compileBytecode
    installFile 644 "$SOURCE_DIR/VERSION"                      "$PREFIX/VERSION"
    installFile 644 "$SOURCE_DIR/requirements.txt"             "$PREFIX/requirements.txt"
    installFile 644 "$SOURCE_DIR/data/$APP_NAME.conf.example"  "$PREFIX/$APP_NAME.conf.example"
    # (Reinstalling from /opt itself: install.sh is already in place)
    [[ $SOURCE_DIR == "$PREFIX" ]] || asRoot install -Dm755 "$SOURCE_DIR/install.sh" "$PREFIX/install.sh"
    installedFiles+=("$PREFIX/install.sh")

    # Remember where we came from, so "update" works without the repository
    local repoUrl="${CACHYOS_SHELLY_UPDATE_REPO:-}"
    [[ -z $repoUrl && -d $SOURCE_DIR/.git ]] && repoUrl="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -n $repoUrl ]]; then
        printf '%s\n' "$repoUrl" | asRoot tee "$PREFIX/REPO" >/dev/null
        printStep "update source: $repoUrl"
    fi

    ensureVenv "$PREFIX/requirements.txt"

    asRoot ln -sfn "$PREFIX/bin/$APP_NAME" "$BIN_LINK"
    installedFiles+=("$BIN_LINK")
    installFile 644 "$SOURCE_DIR/data/$APP_NAME.desktop"       "$APPLICATIONS_DIR/$APP_NAME.desktop"
    installFile 644 "$SOURCE_DIR/data/$APP_NAME-tray.desktop"  "$AUTOSTART_DIR/$APP_NAME-tray.desktop"
    installFile 644 "$SOURCE_DIR/data/$APP_NAME.service"       "$USER_UNIT_DIR/$APP_NAME.service"
    installFile 644 "$SOURCE_DIR/data/$APP_NAME.timer"         "$USER_UNIT_DIR/$APP_NAME.timer"
    installFile 644 "$SOURCE_DIR/data/$APP_NAME-venv.hook"     "$PACMAN_HOOK"
    removeStaleFiles
    printStep "command: $BIN_LINK"
    printStep "app menu entry, tray autostart, systemd timer and pacman hook installed"
}

enableServices() {
    printInfo "Enabling the automatic check and the tray"
    # Timer for every user (the same thing cachy-update does)
    asRoot systemctl --global enable "$APP_NAME.timer" >/dev/null 2>&1 || printWarning "could not enable the timer globally"

    # daemon-reload picks up changed units; restart applies a changed timer
    if asUser systemctl --user daemon-reload 2>/dev/null; then
        asUser systemctl --user restart "$APP_NAME.timer" 2>/dev/null && printStep "timer started"
        # A first check in the background so the tray has data right away
        asUser systemctl --user start --no-block "$APP_NAME.service" 2>/dev/null || true
    else
        printWarning "No user session found; the timer starts at the next login."
    fi
    restartTray
}

# True while any of the given processes still runs
anyAlive() {
    local pid
    for pid; do kill -0 "$pid" 2>/dev/null && return 0; done
    return 1
}

# Stop the running tray (any version) and start the new one in the same
# session. Its environment comes from the old tray's process, so this works
# from sudo, a TTY or SSH too, not only from a terminal inside the desktop.
# Without a running tray, it starts in the current graphical session, if any.
restartTray() {
    local trayPids=() environment=() entry attempt
    if [[ -n $TARGET_USER ]]; then
        mapfile -t trayPids < <(pgrep -u "$TARGET_USER" -f "$TRAY_PROCESS_PATTERN" 2>/dev/null || true)
    fi
    if ((${#trayPids[@]})); then
        # Read as the user: root can't read another user's environ without
        # CAP_SYS_PTRACE (containers, hardened kernels)
        while IFS= read -r -d '' entry; do
            # Set again by the launcher, for the new code's paths
            case $entry in CACHYOS_SHELLY_UPDATE_BIN=*|PYTHONPATH=*) continue ;; esac
            environment+=("$entry")
        done < <(asUser cat "/proc/${trayPids[0]}/environ" 2>/dev/null || cat "/proc/${trayPids[0]}/environ" 2>/dev/null || true)
        kill "${trayPids[@]}" 2>/dev/null || true
        # Up to 3 s for it to go, so the two icons never overlap
        for ((attempt = 0; attempt < 30; attempt++)); do
            anyAlive "${trayPids[@]}" || break
            sleep 0.1
        done
    elif ((EUID != 0)) && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
        mapfile -d '' -t environment < <(env -0)
    fi
    if ((${#environment[@]} == 0)); then
        printStep "the tray appears at the next login"
        return 0
    fi
    asUser env -i "${environment[@]}" setsid "$BIN_LINK" --tray >/dev/null 2>&1 < /dev/null &
    if ((${#trayPids[@]})); then printStep "tray restarted"; else printStep "tray started"; fi
}

checkIcons() {
    if [[ ! -e /usr/share/icons/hicolor/scalable/apps/cachy-update-blue.svg ]]; then
        printWarning "cachy-update icons not found; the tray will use generic theme icons."
        printWarning "To get the same icons: sudo pacman -S cachy-update"
    fi
}

# ---------- cachy-update ----------
# cachy-update (CachyOS's fork of arch-update) does the same job, so two
# tray icons and two checks would compete. It is switched off without
# touching the package's files:
#   - arch-update.timer is enabled per user ("cachy-update --check --enable")
#     or for everyone (systemctl --global): disable whichever is set.
#   - the tray starts from /etc/xdg/autostart/arch-update-tray.desktop
#     (shipped by the CachyOS package) or ~/.config/autostart/ (written by
#     "cachy-update --tray --enable"). A user file with Hidden=true is the
#     XDG way to switch an autostart entry off for one user; the user's own
#     file, if any, is backed up first.
# What was active is recorded, so uninstall can offer to turn exactly that
# back on.
readonly CACHY_TIMER=arch-update.timer
readonly CACHY_TRAY_DESKTOP=arch-update-tray.desktop
readonly CACHY_TRAY_PROCESS=arch-update-tray
readonly CACHY_STATE_FILE=$PREFIX/disabled-cachy-update
readonly CACHY_BACKUP_DIR=$PREFIX/cachy-update-backup
readonly AUTOSTART_OVERRIDE_MARKER="X-Disabled-By=$APP_NAME"

userAutostartFile() { echo "$TARGET_HOME/.config/autostart/$CACHY_TRAY_DESKTOP"; }
userTimerLink()     { echo "$TARGET_HOME/.config/systemd/user/timers.target.wants/$CACHY_TIMER"; }
isHiddenEntry()     { grep -qiE '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true' "$1" 2>/dev/null; }
isOurOverride()     { grep -qxF "$AUTOSTART_OVERRIDE_MARKER" "$1" 2>/dev/null; }

# Does cachy-update's tray start at login for this user?
cachyTrayAutostarts() {
    local userFile
    userFile="$(userAutostartFile)"
    if [[ -f $userFile ]]; then
        if isHiddenEntry "$userFile"; then return 1; fi
        return 0
    fi
    [[ -f $AUTOSTART_DIR/$CACHY_TRAY_DESKTOP ]] && ! isHiddenEntry "$AUTOSTART_DIR/$CACHY_TRAY_DESKTOP"
}

# pgrep/pkill arguments that match cachy-update's tray of the target user
cachyTrayProcessFilter() {
    if [[ -n $TARGET_USER ]]; then
        printf '%s\n' -u "$TARGET_USER" -f "$CACHY_TRAY_PROCESS"
    else
        printf '%s\n' -f "$CACHY_TRAY_PROCESS"
    fi
}

disableCachyUpdate() {
    local disabledItems=() userFile processFilter=()
    mapfile -t processFilter < <(cachyTrayProcessFilter)

    if [[ $(systemctl --global is-enabled "$CACHY_TIMER" 2>/dev/null) == enabled ]] \
        && asRoot systemctl --global disable "$CACHY_TIMER" >/dev/null 2>&1; then
        disabledItems+=(global-timer)
    fi
    if [[ -n $TARGET_HOME ]]; then
        if [[ -L $(userTimerLink) || -e $(userTimerLink) ]] \
            && asUser systemctl --user disable --now "$CACHY_TIMER" >/dev/null 2>&1; then
            disabledItems+=(user-timer)
        fi
        # Also stops a timer that only the global setting had started
        asUser systemctl --user stop "$CACHY_TIMER" >/dev/null 2>&1 || true

        if cachyTrayAutostarts; then
            userFile="$(userAutostartFile)"
            if [[ -f $userFile ]]; then
                asRoot install -Dm644 "$userFile" "$CACHY_BACKUP_DIR/$CACHY_TRAY_DESKTOP"
                disabledItems+=(autostart-backup)
            fi
            asUser mkdir -p "$(dirname "$userFile")"
            printf '[Desktop Entry]\nHidden=true\n%s\n' "$AUTOSTART_OVERRIDE_MARKER" | asUser tee "$userFile" >/dev/null
            disabledItems+=(autostart-override)
        fi
    fi
    if pgrep "${processFilter[@]}" >/dev/null 2>&1; then
        pkill "${processFilter[@]}" 2>/dev/null || true
        disabledItems+=(tray-running)
    fi

    if ((${#disabledItems[@]})); then
        # Merge with an earlier install's record: a reinstall finds it already off
        {
            cat "$CACHY_STATE_FILE" 2>/dev/null || true
            printf '%s\n' "${disabledItems[@]}"
        } | sort -u | asRoot tee "$CACHY_STATE_FILE.tmp" >/dev/null
        asRoot mv -f "$CACHY_STATE_FILE.tmp" "$CACHY_STATE_FILE"
        printStep "cachy-update disabled ($(describeCachyItems "${disabledItems[@]}")); uninstall offers to turn it back on"
    elif [[ -s $CACHY_STATE_FILE ]]; then
        printStep "cachy-update: already disabled by an earlier install"
    else
        printStep "cachy-update: not active"
    fi
}

describeCachyItems() {
    local item descriptions=()
    # Fixed order, whatever order the record lists them in
    for item in global-timer user-timer autostart-override tray-running; do
        printf '%s\n' "$@" | grep -qxF "$item" || continue
        case $item in
            global-timer)       descriptions+=("timer for all users") ;;
            user-timer)         descriptions+=("timer") ;;
            autostart-override) descriptions+=("tray at login") ;;
            tray-running)       descriptions+=("running tray") ;;
        esac
    done
    local IFS=,
    local joined="${descriptions[*]}"
    echo "${joined//,/, }"
}

# Offer to turn back on exactly what disableCachyUpdate turned off
restoreCachyUpdate() {
    local disabledItems=() userFile
    [[ -s $CACHY_STATE_FILE ]] || return 0
    mapfile -t disabledItems < "$CACHY_STATE_FILE"
    userFile="$(userAutostartFile)"
    hasItem() { printf '%s\n' "${disabledItems[@]}" | grep -qxF "$1"; }

    echo
    if ! command -v arch-update >/dev/null 2>&1; then
        printStep "cachy-update was active before $APP_NAME, but it is no longer installed"
        [[ -n $TARGET_HOME ]] && isOurOverride "$userFile" && asUser rm -f "$userFile"
        return 0
    fi
    printInfo "cachy-update was active before $APP_NAME was installed ($(describeCachyItems "${disabledItems[@]}"))."
    if ! confirm "Turn cachy-update back on?" Y; then
        printStep "cachy-update left off"
        if [[ -n $TARGET_HOME ]] && isOurOverride "$userFile"; then
            echo "   Its tray stays off at login through $userFile; delete that file to undo it."
        fi
        return 0
    fi

    if hasItem global-timer; then
        asRoot systemctl --global enable "$CACHY_TIMER" >/dev/null 2>&1 || printWarning "could not re-enable $CACHY_TIMER globally"
    fi
    if [[ -n $TARGET_HOME ]]; then
        if hasItem user-timer; then
            asUser systemctl --user enable --now "$CACHY_TIMER" >/dev/null 2>&1 || printWarning "could not re-enable $CACHY_TIMER"
        elif hasItem global-timer; then
            asUser systemctl --user start "$CACHY_TIMER" >/dev/null 2>&1 || true
        fi
        if hasItem autostart-override && isOurOverride "$userFile"; then
            if hasItem autostart-backup && [[ -f $CACHY_BACKUP_DIR/$CACHY_TRAY_DESKTOP ]]; then
                asUser install -Dm644 "$CACHY_BACKUP_DIR/$CACHY_TRAY_DESKTOP" "$userFile"
            else
                asUser rm -f "$userFile"
            fi
        fi
    fi
    # Start its tray now in the current graphical session
    if { hasItem tray-running || hasItem autostart-override; } \
        && ((EUID != 0)) && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
        setsid arch-update --tray >/dev/null 2>&1 < /dev/null &
    fi
    printStep "cachy-update turned back on"
}

# ---------- commands ----------
cmdInstall() {
    command -v pacman >/dev/null || die "This installer is for Arch/CachyOS (pacman not found)."
    local installedVersion=""
    [[ -f $PREFIX/VERSION ]] && installedVersion="$(cat "$PREFIX/VERSION")"
    printInfo "$APP_NAME $(cat "$SOURCE_DIR/VERSION")${installedVersion:+ (installed: $installedVersion)}"

    ((EUID != 0)) && { sudo -v || die "sudo is required"; }
    asRoot mkdir -p "$PREFIX"
    printInfo "Checking optional tools"
    offerAurHelper              # first: the dependencies may need it for the AUR
    ensureDependencies
    printInfo "Update sources"
    chooseSources
    offerSourceTools
    installFiles
    offerSourceUserTools
    saveSources
    disableCachyUpdate
    enableServices
    checkIcons

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

# Show the source list again and install the tools of newly picked sources
cmdSources() {
    [[ -f $PREFIX/VERSION ]] || die "$APP_NAME isn't installed. Run: $0 install"
    ((EUID != 0)) && { sudo -v || die "sudo is required"; }
    printInfo "Update sources"
    chooseSources 1
    offerSourceTools
    offerSourceUserTools
    saveSources
    echo
    printInfo "Saved. The next check uses them: $(printf '%s ' "${pickedSources[@]}")"
}

# Called by the pacman hook after python is upgraded (runs as root, no prompts):
# rebuilds the venv if needed and the bytecode for the new Python
cmdRebuildVenv() {
    ((EUID == 0)) || die "rebuild-venv is run by pacman as root."
    [[ -f $PREFIX/requirements.txt ]] || exit 0
    # A subshell, so a failure (e.g. no network) warns instead of failing pacman's hook
    (ensureVenv "$PREFIX/requirements.txt") \
        || printWarning "The updater runs on the system python3 meanwhile; run '$PREFIX/install.sh update' to repair the tray."
    compileBytecode
}

cmdUninstall() {
    printInfo "Removing $APP_NAME"
    ((EUID != 0)) && { sudo -v || die "sudo is required"; }

    # Read what we installed before $PREFIX is gone
    local addedPackages=() addedAppman="" installedPaths=() path
    [[ -f $INSTALLED_PACKAGES_FILE ]] && mapfile -t addedPackages < "$INSTALLED_PACKAGES_FILE"
    [[ -f $INSTALLED_APPMAN_FILE ]] && addedAppman="$(cat "$INSTALLED_APPMAN_FILE")"
    [[ -f $MANIFEST_FILE ]] && mapfile -t installedPaths < "$MANIFEST_FILE"

    if [[ -n $TARGET_USER ]]; then
        pkill -u "$TARGET_USER" -f "$TRAY_PROCESS_PATTERN" 2>/dev/null || true
        asUser systemctl --user disable --now "$APP_NAME.timer" >/dev/null 2>&1 || true
    fi
    asRoot systemctl --global disable "$APP_NAME.timer" >/dev/null 2>&1 || true

    # The manifest, plus the fixed list for installs from before it (<= 2.1.0)
    asRoot rm -f "$BIN_LINK" "$APPLICATIONS_DIR/$APP_NAME.desktop" "$AUTOSTART_DIR/$APP_NAME-tray.desktop" \
                 "$USER_UNIT_DIR/$APP_NAME.service" "$USER_UNIT_DIR/$APP_NAME.timer" "$PACMAN_HOOK"
    for path in "${installedPaths[@]}"; do
        [[ $path == "$PREFIX"/* ]] && continue      # goes with $PREFIX below
        if isOwnedPath "$path"; then asRoot rm -rf -- "${path%/}"; fi
    done
    asUser systemctl --user daemon-reload >/dev/null 2>&1 || true
    # Our timer and tray are gone: now cachy-update can come back. It needs
    # the record and the backup in $PREFIX, so it runs before $PREFIX is deleted.
    local hadCachyRecord=0
    [[ -s $CACHY_STATE_FILE ]] && hadCachyRecord=1
    restoreCachyUpdate
    # $PREFIX holds the virtualenv too, so this removes PyQt6 as well
    asRoot rm -rf "$PREFIX"
    printStep "files removed (including the virtualenv)"

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
    if ((!hadCachyRecord)) && command -v arch-update >/dev/null 2>&1; then
        echo "   To use cachy-update: CachyOS Hello > Apps/Tweaks > Cachy Update"
    fi
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
    local entry dependency repoPackage aurPackage requirement appmanPath key
    for entry in "${DEPENDENCIES[@]}"; do
        IFS='|' read -r dependency repoPackage aurPackage requirement <<<"$entry"
        if isSatisfied "$dependency"; then
            printStep "$dependency: ${GREEN}ok${RESET}"
        else
            printStep "$dependency: ${RED}missing${RESET} ($requirement)"
        fi
    done
    local helper
    if helper="$(aurHelper)"; then printStep "AUR helper: ${GREEN}$helper${RESET}"; else printStep "AUR helper: not installed"; fi
    if isSatisfied flatpak; then
        printStep "flatpak: ${GREEN}ok${RESET}"
        if isSatisfied shelly-flatpak-backend; then printStep "shelly-flatpak-backend: ${GREEN}ok${RESET}"; else printStep "shelly-flatpak-backend: missing"; fi
        if hasFlathub; then printStep "flathub: ${GREEN}ok${RESET}"; else printStep "flathub: not added"; fi
    else
        printStep "flatpak: not installed"
    fi
    if appmanPath="$(findAppman)"; then printStep "appman: ${GREEN}ok${RESET} ($appmanPath)"; else printStep "appman: not installed"; fi
    local venvPython
    if [[ -x $VENV_DIR/bin/python ]] && venvPython="$(pythonVersion "$VENV_DIR/bin/python")"; then
        printStep "updater Python: ${GREEN}virtualenv${RESET} (Python $venvPython)"
    else
        printStep "updater Python: ${YELLOW}system python3${RESET} (virtualenv broken or missing; run: $PREFIX/install.sh update)"
    fi
    if "$VENV_DIR/bin/python" -c 'import PyQt6' 2>/dev/null; then
        printStep "tray (PyQt6 in the virtualenv): ${GREEN}ok${RESET}"
    else
        printStep "tray (PyQt6 in the virtualenv): ${RED}broken or missing${RESET} (run: $PREFIX/install.sh update)"
    fi

    printInfo "Update sources"
    if [[ -s $SOURCES_FILE ]]; then
        readSavedSources
        for key in "${pickedSources[@]}"; do printStep "$(sourceTitle "$key")"; done
    else
        printStep "all (none picked yet: $PREFIX/install.sh sources)"
    fi

    printInfo "Services"
    printStep "timer: $(asUser systemctl --user is-active "$APP_NAME.timer" 2>/dev/null || echo inactive)"
    if pgrep -f "$TRAY_PROCESS_PATTERN" >/dev/null; then printStep "tray: running"; else printStep "tray: stopped"; fi
    if [[ -s $CACHY_STATE_FILE ]]; then
        local cachyItems=()
        mapfile -t cachyItems < "$CACHY_STATE_FILE"
        printStep "cachy-update: disabled by $APP_NAME ($(describeCachyItems "${cachyItems[@]}")); uninstall offers to turn it back on"
    elif command -v arch-update >/dev/null 2>&1; then
        printStep "cachy-update: installed, not disabled by $APP_NAME"
    fi
}

# ---------- main ----------
main() {
    local command=""
    while (($#)); do
        case "$1" in
            install|update|sources|uninstall|status|rebuild-venv) command="$1" ;;
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
        sources)      cmdSources ;;
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
