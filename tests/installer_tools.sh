#!/usr/bin/env bash
#
# Tests install.sh's optional tools: offering an AUR helper (yay), Flatpak
# with Shelly's backend and Flathub, and AppMan when they are missing; and
# the list of update sources (picked, saved, their tools offered).
# Runs the real installer functions against fake pacman/flatpak/git/makepkg/
# curl/sudo, from a copy of install.sh whose /opt path points into a
# temporary directory: nothing real is touched.
# Runs in CI (bash:5 image) and locally: bash tests/installer_tools.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FAKE_BIN="$TEMP_DIR/bin"
HOME_DIR="$TEMP_DIR/home"
PREFIX_DIR="$TEMP_DIR/opt/cachyos-shelly-update"
OUTPUT_FILE="$TEMP_DIR/output"
# The fake system: installed packages, what the repositories have, remotes
export INSTALLED_FILE="$TEMP_DIR/installed" REPOS_FILE="$TEMP_DIR/repos" REMOTES_FILE="$TEMP_DIR/remotes"
export CALL_LOG="$TEMP_DIR/calls.log" FAKE_BIN

# ---------- fakes ----------
# pacman: -T/-Q check $INSTALLED_FILE, -Si checks $REPOS_FILE, -S installs.
# Installing a package with a command (yay, flatpak, paru) puts a fake one on PATH.
mkdir -p "$TEMP_DIR/fakes"
cat > "$TEMP_DIR/fakes/pacman" <<'EOF'
#!/usr/bin/env bash
echo "pacman $*" >> "$CALL_LOG"
installCommand() {
    case $1 in
        yay|yay-bin) ln -sf "$FAKE_BIN/.helper" "$FAKE_BIN/yay" ;;
        flatpak)     ln -sf "$FAKE_BIN/.flatpak" "$FAKE_BIN/flatpak" ;;
    esac
}
case $1 in
    -T|-Q) grep -qxF "$2" "$INSTALLED_FILE" ;;
    -Si)   grep -qxF "$2" "$REPOS_FILE" ;;
    -S)    for arg in "${@:2}"; do
               [[ $arg == -* ]] && continue
               grep -qxF "$arg" "$REPOS_FILE" || exit 1
               echo "$arg" >> "$INSTALLED_FILE"; installCommand "$arg"
           done ;;
    -U)    echo yay-bin >> "$INSTALLED_FILE"; installCommand yay-bin ;;
esac
EOF
cat > "$TEMP_DIR/fakes/flatpak" <<'EOF'
#!/usr/bin/env bash
echo "flatpak $*" >> "$CALL_LOG"
case $1 in
    remotes)    cat "$REMOTES_FILE" 2>/dev/null ;;
    remote-add) echo "$3" >> "$REMOTES_FILE" ;;
esac
EOF
cat > "$TEMP_DIR/fakes/helper" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$CALL_LOG"
EOF
cat > "$TEMP_DIR/fakes/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$CALL_LOG"
[[ $1 == clone ]] && mkdir -p "${!#}"
exit 0
EOF
# makepkg -si installs the package it built (through pacman -U)
cat > "$TEMP_DIR/fakes/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "makepkg $* in $(basename "$PWD")" >> "$CALL_LOG"
pacman -U ./*.pkg.tar.zst
EOF
cat > "$TEMP_DIR/fakes/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALL_LOG"
while (($#)); do [[ $1 == -o ]] && { printf '#!/bin/sh\nAMVERSION="10.7-1"\n' > "$2"; }; shift; done
EOF
cat > "$TEMP_DIR/fakes/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -u ]] && shift 2
exec env "$@"
EOF
chmod +x "$TEMP_DIR"/fakes/*

INSTALLER_LIB="$TEMP_DIR/installer-lib.sh"
sed -e "s#^readonly PREFIX=.*#readonly PREFIX=$PREFIX_DIR#" \
    -e '/^readonly SUDO_COMMAND TARGET_USER$/d' \
    -e '/^readonly TARGET_UID TARGET_HOME$/d' \
    -e '/^main "\$@"$/,$d' \
    "$REPO_ROOT/install.sh" > "$INSTALLER_LIB"

failureCount=0
# runInstaller "<installer function calls>" [answers, one per line]
runInstaller() {
    if ! printf '%s\n' "${2:-}" | HOME="$HOME_DIR" PATH="$FAKE_BIN:$PATH" bash -c "
        source '$INSTALLER_LIB'
        SUDO_COMMAND=()
        TARGET_USER=tester TARGET_UID=\$(id -u) TARGET_HOME='$HOME_DIR'
        assumeYes=${ASSUME_YES:-0}
        $1" > "$OUTPUT_FILE" 2>&1; then
        printf 'FAIL  installer call failed: %s\n' "$1"
        sed 's/^/      /' "$OUTPUT_FILE"
        failureCount=$((failureCount + 1))
    fi
}
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok    %s\n' "$description"
    else
        printf 'FAIL  %s\n' "$description"
        sed 's/^/      /' "$OUTPUT_FILE"
        failureCount=$((failureCount + 1))
    fi
}
not()          { ! "$@"; }
isInstalled()  { grep -qxF "$1" "$INSTALLED_FILE"; }
called()       { grep -qF -- "$1" "$CALL_LOG" 2>/dev/null; }
outputHas()    { grep -qF -- "$1" "$OUTPUT_FILE"; }
recorded()     { grep -qxF "$1" "$PREFIX_DIR/installed-packages" 2>/dev/null; }
declined()     { grep -qxF "$1" "$PREFIX_DIR/declined-tools" 2>/dev/null; }

# resetState "<installed packages>" "<repository packages>" "<flatpak remotes>"
resetState() {
    rm -rf "$HOME_DIR" "${TEMP_DIR:?}/opt" "$FAKE_BIN" "$CALL_LOG"
    mkdir -p "$HOME_DIR" "$PREFIX_DIR" "$FAKE_BIN"
    cp "$TEMP_DIR/fakes/pacman" "$TEMP_DIR/fakes/git" "$TEMP_DIR/fakes/makepkg" \
       "$TEMP_DIR/fakes/curl" "$TEMP_DIR/fakes/sudo" "$FAKE_BIN/"
    cp "$TEMP_DIR/fakes/helper" "$FAKE_BIN/.helper"
    cp "$TEMP_DIR/fakes/flatpak" "$FAKE_BIN/.flatpak"
    tr ' ' '\n' <<<"$1" | grep . > "$INSTALLED_FILE" || : > "$INSTALLED_FILE"
    tr ' ' '\n' <<<"$2" | grep . > "$REPOS_FILE" || : > "$REPOS_FILE"
    tr ' ' '\n' <<<"$3" | grep . > "$REMOTES_FILE" || : > "$REMOTES_FILE"
    isInstalled flatpak && ln -sf "$FAKE_BIN/.flatpak" "$FAKE_BIN/flatpak"
    isInstalled yay && ln -sf "$FAKE_BIN/.helper" "$FAKE_BIN/yay"
    isInstalled paru && ln -sf "$FAKE_BIN/.helper" "$FAKE_BIN/paru"
    return 0
}
OFFER_ALL="offerAurHelper; offerFlatpak; offerAppman; recordInstalledPackages"

# ---------- A: nothing installed, CachyOS repositories, -y ----------
resetState "" "yay flatpak shelly-flatpak-backend" ""
ASSUME_YES=1 runInstaller "$OFFER_ALL"
check "A: yay installed from the repositories" isInstalled yay
check "A: flatpak installed" isInstalled flatpak
check "A: Shelly's Flatpak backend installed" isInstalled shelly-flatpak-backend
check "A: Flathub added system-wide" called "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
check "A: AppMan downloaded" test -x "$HOME_DIR/.local/bin/appman"
check "A: everything added is recorded for --purge" recorded yay
check "A: flatpak recorded" recorded flatpak
check "A: the backend recorded" recorded shelly-flatpak-backend
check "A: AppMan recorded" test -s "$PREFIX_DIR/installed-appman"

# ---------- B: yay not in the repositories (plain Arch): build yay-bin ----------
resetState "flatpak shelly-flatpak-backend" "git base-devel" "flathub"
touch "$HOME_DIR/.keep"; mkdir -p "$HOME_DIR/.local/bin"; printf '#!/bin/sh\n' > "$HOME_DIR/.local/bin/appman"; chmod +x "$HOME_DIR/.local/bin/appman"
runInstaller offerAurHelper "y"
check "B: asks about yay" outputHas "Install yay"
check "B: installs git and base-devel to build it" isInstalled base-devel
check "B: clones yay-bin from the AUR" called "git clone --quiet --depth 1 https://aur.archlinux.org/yay-bin.git"
check "B: builds and installs it with makepkg" called "makepkg -si --needed --noconfirm in yay-bin"
check "B: yay works afterwards" test -x "$FAKE_BIN/yay"

# ---------- C: paru is enough ----------
resetState "paru" "yay" ""
runInstaller offerAurHelper
check "C: paru counts as the AUR helper" outputHas "AUR helper: paru"
check "C: yay isn't offered" not outputHas "Install yay"
check "C: nothing installed" not isInstalled yay

# ---------- D: saying no, then updating ----------
resetState "" "yay flatpak shelly-flatpak-backend" ""
runInstaller "$OFFER_ALL" $'n\nn\nn'
check "D: nothing installed when declining" not isInstalled yay
check "D: no flatpak" not isInstalled flatpak
check "D: no AppMan" test ! -e "$HOME_DIR/.local/bin/appman"
check "D: the answers are remembered" declined yay
check "D: flatpak remembered" declined flatpak
check "D: appman remembered" declined appman
runInstaller "$OFFER_ALL"
check "D: an update doesn't ask again" not outputHas "?"

# ---------- E: Flatpak without Flathub and without Shelly's backend ----------
resetState "flatpak yay" "shelly-flatpak-backend" ""
runInstaller offerFlatpak $'y\ny'
check "E: offers Shelly's Flatpak backend" outputHas "Shelly's Flatpak backend is missing"
check "E: installs it" isInstalled shelly-flatpak-backend
check "E: offers Flathub" outputHas "Add Flathub?"
check "E: adds it" called "flatpak remote-add --if-not-exists flathub"

# ---------- F: everything there: no questions ----------
resetState "yay flatpak shelly-flatpak-backend" "" "flathub"
mkdir -p "$HOME_DIR/.local/bin"; printf '#!/bin/sh\n' > "$HOME_DIR/.local/bin/appman"; chmod +x "$HOME_DIR/.local/bin/appman"
runInstaller "$OFFER_ALL"
check "F: no questions when everything is installed" not outputHas "?"
check "F: no packages installed" not called "pacman -S "
check "F: reports them" outputHas "flathub: "


# ---------- update sources ----------
sources()      { tr '\n' ' ' < "$PREFIX_DIR/sources" 2>/dev/null; }
hasSources()   { [[ "$(sources)" == "$1" ]]; }
CHOOSE="chooseSources; offerSourceTools; offerSourceUserTools; saveSources"

# G: nothing optional installed, Enter: what is there is picked, the rest remembered as "no"
resetState "" "flatpak shelly-flatpak-backend" ""
runInstaller "$CHOOSE" ""
check "G: shows the list" outputHas "What should cachyos-shelly-update update?"
check "G: says what isn't installed" outputHas "Flatpak not installed: offered when picked"
check "G: picks what Shelly covers" hasSources "repo aur appimage "
check "G: installs nothing" not isInstalled flatpak
check "G: remembers Flatpak as not wanted" declined flatpak
check "G: remembers AppMan as not wanted" declined appman

# H: picking Flatpak and AppMan offers and installs them
resetState "" "flatpak shelly-flatpak-backend" ""
runInstaller "$CHOOSE" $'3 5\n\ny\ny\ny'
check "H: Flatpak installed" isInstalled flatpak
check "H: with Shelly's backend" isInstalled shelly-flatpak-backend
check "H: AppMan downloaded" test -x "$HOME_DIR/.local/bin/appman"
check "H: both saved" hasSources "repo aur flatpak appimage appman "
check "H: no \"no\" left behind" not declined flatpak

# I: Flatpak installed but left out: never used
resetState "flatpak shelly-flatpak-backend" "" "flathub"
runInstaller "$CHOOSE" $'3\n'
check "I: Flatpak left out" hasSources "repo aur appimage "
check "I: remembered" declined flatpak

# J: a saved choice is kept without asking (updates)
runInstaller "$CHOOSE" ""
check "J: no list when a choice is saved" not outputHas "What should"
check "J: shows the saved choice" outputHas "change them with:"
check "J: keeps it" hasSources "repo aur appimage "

# K: "install.sh sources" shows the list again, starting from the saved choice
runInstaller "chooseSources 1; offerSourceTools; offerSourceUserTools; saveSources" $'3\n'
check "K: shows the list again" outputHas "What should"
check "K: Flatpak picked again" hasSources "repo aur flatpak appimage "
check "K: its \"no\" is cleared" not declined flatpak

# L: picked, but its install turned down: left out, with a warning
resetState "" "flatpak shelly-flatpak-backend" ""
runInstaller "$CHOOSE" $'3\n\nn'
check "L: Flatpak not installed" not isInstalled flatpak
check "L: left out of the choice" hasSources "repo aur appimage "
check "L: says so" outputHas "Flatpak isn't installed"

# M: -y picks everything not turned down before, and installs it
resetState "" "flatpak shelly-flatpak-backend" ""
printf 'appman\n' > "$PREFIX_DIR/declined-tools"
ASSUME_YES=1 runInstaller "$CHOOSE"
check "M: -y doesn't show the list" not outputHas "What should"
check "M: -y installs Flatpak" isInstalled flatpak
check "M: -y respects an earlier \"no\"" hasSources "repo aur flatpak appimage "

# N: unpicking everything isn't accepted
resetState "" "" ""
runInstaller "$CHOOSE" $'1 2 4\n\n'
check "N: asks for at least one" outputHas "Pick at least one source."
check "N: falls back to the defaults" hasSources "repo aur appimage "

echo
if ((failureCount)); then echo "$failureCount test(s) failed"; exit 1; fi
echo "all tests passed"
