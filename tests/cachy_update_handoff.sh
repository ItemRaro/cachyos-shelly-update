#!/usr/bin/env bash
#
# Tests install.sh's cachy-update handoff: switching cachy-update off at
# install, and offering to turn exactly that back on at uninstall.
# Runs the real installer functions against fake systemctl/pgrep/pkill/
# sudo/arch-update, from a copy of install.sh whose /opt and
# /etc/xdg/autostart paths point into a temporary directory: nothing real
# is touched. Runs in CI (bash:5 image) and locally: bash tests/cachy_update_handoff.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FAKE_BIN="$TEMP_DIR/bin"
CACHY_BIN="$TEMP_DIR/cachy-bin"          # holds arch-update; dropped from PATH to "uninstall" it
HOME_DIR="$TEMP_DIR/home"
PREFIX_DIR="$TEMP_DIR/opt/cachyos-shelly-update"
SYSTEM_AUTOSTART_DIR="$TEMP_DIR/etc/xdg/autostart"
USER_AUTOSTART_FILE="$HOME_DIR/.config/autostart/arch-update-tray.desktop"
USER_WANTS_DIR="$HOME_DIR/.config/systemd/user/timers.target.wants"
GLOBAL_UNITS_DIR="$TEMP_DIR/global-units"
STATE_FILE="$PREFIX_DIR/disabled-cachy-update"
BACKUP_FILE="$PREFIX_DIR/cachy-update-backup/arch-update-tray.desktop"
TRAY_RUNNING_FLAG="$TEMP_DIR/tray-running"
export CALL_LOG="$TEMP_DIR/calls.log" USER_WANTS_DIR GLOBAL_UNITS_DIR TRAY_RUNNING_FLAG
mkdir -p "$FAKE_BIN" "$CACHY_BIN"

# ---------- fakes ----------
# systemctl: --global units live in $GLOBAL_UNITS_DIR, --user ones as links in
# the user's timers.target.wants (where install.sh looks for them)
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALL_LOG"
scope=user
args=()
for arg in "$@"; do
    case $arg in
        --global) scope=global ;;
        --user) scope=user ;;
        --now|-q|--quiet) ;;
        *) args+=("$arg") ;;
    esac
done
if [[ $scope == global ]]; then unitDir=$GLOBAL_UNITS_DIR; else unitDir=$USER_WANTS_DIR; fi
case ${args[0]} in
    is-enabled)
        if [[ -e $unitDir/${args[1]} ]] || [[ $scope == user && -e $GLOBAL_UNITS_DIR/${args[1]} ]]; then
            echo enabled; exit 0
        fi
        echo disabled; exit 1 ;;
    enable)  mkdir -p "$unitDir"; for unit in "${args[@]:1}"; do touch "$unitDir/$unit"; done ;;
    disable) for unit in "${args[@]:1}"; do rm -f "$unitDir/$unit"; done ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "pgrep $*" >> "$CALL_LOG"
[[ -e $TRAY_RUNNING_FLAG ]]
EOF
cat > "$FAKE_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
echo "pkill $*" >> "$CALL_LOG"
rm -f "$TRAY_RUNNING_FLAG"
EOF
# sudo -u USER VAR=value... command: just run the command as ourselves
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -u ]] && shift 2
exec env "$@"
EOF
cat > "$CACHY_BIN/arch-update" <<'EOF'
#!/usr/bin/env bash
echo "arch-update $*" >> "$CALL_LOG"
EOF
chmod +x "$FAKE_BIN"/* "$CACHY_BIN"/*

# install.sh with the system paths pointed into $TEMP_DIR and main() removed,
# so its functions can be called one by one
INSTALLER_LIB="$TEMP_DIR/installer-lib.sh"
sed -e "s#^readonly PREFIX=.*#readonly PREFIX=$PREFIX_DIR#" \
    -e "s#^readonly AUTOSTART_DIR=.*#readonly AUTOSTART_DIR=$SYSTEM_AUTOSTART_DIR#" \
    -e '/^readonly SUDO_COMMAND TARGET_USER$/d' \
    -e '/^readonly TARGET_UID TARGET_HOME$/d' \
    -e '/^main "\$@"$/,$d' \
    "$REPO_ROOT/install.sh" > "$INSTALLER_LIB"

# runInstaller "<installer function calls>" [stdin] -> output in $OUTPUT_FILE
OUTPUT_FILE="$TEMP_DIR/output"
runInstaller() {
    local pathValue="$FAKE_BIN:$CACHY_BIN:$PATH"
    [[ ${CACHY_UNINSTALLED:-0} == 1 ]] && pathValue="$FAKE_BIN:$PATH"
    if ! printf '%s\n' "${2:-}" | PATH="$pathValue" WAYLAND_DISPLAY="" DISPLAY="" bash -c "
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

# resetState: a clean "computer" with cachy-update installed and nothing enabled
resetState() {
    rm -rf "$HOME_DIR" "${TEMP_DIR:?}/opt" "${TEMP_DIR:?}/etc" "$GLOBAL_UNITS_DIR" "$TRAY_RUNNING_FLAG" "$CALL_LOG"
    mkdir -p "$HOME_DIR" "$PREFIX_DIR" "$SYSTEM_AUTOSTART_DIR" "$GLOBAL_UNITS_DIR"
    printf '[Desktop Entry]\nName=Cachy-Update Systray Applet\nExec=/bin/sh -c "sleep 3 && arch-update --tray"\n' \
        > "$SYSTEM_AUTOSTART_DIR/arch-update-tray.desktop"
}

failureCount=0
# check "description" command...  (passes when the command succeeds)
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
stateHas()     { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
stateHasAll()  { local item; for item in "$@"; do stateHas "$item" || return 1; done; }
stateHasNone() { local item; for item in "$@"; do stateHas "$item" && return 1; done; return 0; }
outputHas()    { grep -qF -- "$1" "$OUTPUT_FILE"; }

# ---------- A: everything on (global + user timer, user's own autostart file, tray running) ----------
resetState
touch "$GLOBAL_UNITS_DIR/arch-update.timer" "$TRAY_RUNNING_FLAG"
mkdir -p "$USER_WANTS_DIR" "$(dirname "$USER_AUTOSTART_FILE")"
touch "$USER_WANTS_DIR/arch-update.timer"
printf '[Desktop Entry]\nExec=my custom tray command\n' > "$USER_AUTOSTART_FILE"
cp "$USER_AUTOSTART_FILE" "$TEMP_DIR/original-user-autostart"

runInstaller disableCachyUpdate
check "A: install disables the global timer" test ! -e "$GLOBAL_UNITS_DIR/arch-update.timer"
check "A: install disables the user timer" test ! -e "$USER_WANTS_DIR/arch-update.timer"
check "A: install hides the tray autostart for the user" grep -q "^Hidden=true" "$USER_AUTOSTART_FILE"
check "A: install backs up the user's own autostart file" cmp -s "$BACKUP_FILE" "$TEMP_DIR/original-user-autostart"
check "A: install stops the running tray" grep -q "^pkill .*arch-update-tray" "$CALL_LOG"
check "A: the tray is no longer running" test ! -e "$TRAY_RUNNING_FLAG"
check "A: install never touches the system autostart file" grep -q "^Exec=" "$SYSTEM_AUTOSTART_DIR/arch-update-tray.desktop"
check "A: everything is recorded" stateHasAll global-timer user-timer autostart-override autostart-backup tray-running
check "A: install says what it disabled" outputHas "cachy-update disabled (timer for all users, timer, tray at login, running tray)"

cp "$STATE_FILE" "$TEMP_DIR/state-after-install"
runInstaller disableCachyUpdate
check "A: a reinstall keeps the record" cmp -s "$STATE_FILE" "$TEMP_DIR/state-after-install"
check "A: a reinstall reports it was already disabled" outputHas "already disabled by an earlier install"
check "A: a reinstall doesn't back up its own override" cmp -s "$BACKUP_FILE" "$TEMP_DIR/original-user-autostart"

ASSUME_YES=1 runInstaller restoreCachyUpdate
check "A: uninstall asks about exactly what was disabled" \
    outputHas "was active before cachyos-shelly-update was installed (timer for all users, timer, tray at login, running tray)"
check "A: uninstall re-enables the global timer" test -e "$GLOBAL_UNITS_DIR/arch-update.timer"
check "A: uninstall re-enables the user timer" test -e "$USER_WANTS_DIR/arch-update.timer"
check "A: uninstall restores the user's own autostart file" cmp -s "$USER_AUTOSTART_FILE" "$TEMP_DIR/original-user-autostart"
check "A: uninstall confirms it" outputHas "cachy-update turned back on"

# ---------- B: CachyOS default (system autostart only, tray running), answer "y" ----------
resetState
touch "$TRAY_RUNNING_FLAG"
runInstaller disableCachyUpdate
check "B: install hides the system autostart entry with a user override" grep -q "^Hidden=true" "$USER_AUTOSTART_FILE"
check "B: nothing to back up" test ! -e "$BACKUP_FILE"
check "B: no backup recorded" not stateHas autostart-backup
check "B: timers weren't on, so they aren't recorded" stateHasNone global-timer user-timer
runInstaller restoreCachyUpdate "y"
check "B: answering y removes the override" test ! -e "$USER_AUTOSTART_FILE"
check "B: the system autostart file is still there" test -f "$SYSTEM_AUTOSTART_DIR/arch-update-tray.desktop"
check "B: no user timer is enabled that wasn't before" test ! -e "$USER_WANTS_DIR/arch-update.timer"
check "B: no global timer is enabled that wasn't before" test ! -e "$GLOBAL_UNITS_DIR/arch-update.timer"

# ---------- C: declining ----------
resetState
mkdir -p "$USER_WANTS_DIR"
touch "$USER_WANTS_DIR/arch-update.timer"
runInstaller disableCachyUpdate
runInstaller restoreCachyUpdate "n"
check "C: answering n leaves the timer off" test ! -e "$USER_WANTS_DIR/arch-update.timer"
check "C: answering n leaves the tray off" grep -q "^Hidden=true" "$USER_AUTOSTART_FILE"
check "C: it says cachy-update was left off" outputHas "left off"
check "C: and how to undo it" outputHas "delete that file to undo it"

# ---------- D: nothing active ----------
resetState
rm -f "$SYSTEM_AUTOSTART_DIR/arch-update-tray.desktop"
runInstaller disableCachyUpdate
check "D: install reports cachy-update not active" outputHas "cachy-update: not active"
check "D: nothing is recorded" test ! -e "$STATE_FILE"
check "D: no override is written" test ! -e "$USER_AUTOSTART_FILE"
runInstaller restoreCachyUpdate
check "D: uninstall doesn't ask anything" test ! -s "$OUTPUT_FILE"

# ---------- E: cachy-update uninstalled in the meantime ----------
resetState
runInstaller disableCachyUpdate
CACHY_UNINSTALLED=1 runInstaller restoreCachyUpdate
check "E: uninstall says cachy-update is gone" outputHas "no longer installed"
check "E: and removes the leftover override" test ! -e "$USER_AUTOSTART_FILE"

# ---------- F: the user had already hidden it themselves ----------
resetState
mkdir -p "$(dirname "$USER_AUTOSTART_FILE")"
printf '[Desktop Entry]\nHidden=true\n' > "$USER_AUTOSTART_FILE"
cp "$USER_AUTOSTART_FILE" "$TEMP_DIR/user-hidden-autostart"
runInstaller disableCachyUpdate
check "F: a tray the user already hid counts as not active" outputHas "cachy-update: not active"
check "F: the user's own file is left alone" cmp -s "$USER_AUTOSTART_FILE" "$TEMP_DIR/user-hidden-autostart"

echo
if ((failureCount)); then echo "$failureCount test(s) failed"; exit 1; fi
echo "all tests passed"
