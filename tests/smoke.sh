#!/usr/bin/env bash
#
# Smoke test for cachyos-shelly-update that never touches the system:
# fake "shelly" and "appman" commands, temporary HOME/XDG_* dirs, no sudo/pacman.
# Runs in CI (bash:5 image) and locally: bash tests/smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
UPDATER="$REPO_ROOT/src/cachyos-shelly-update"
INSTALLER="$REPO_ROOT/install.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export HOME="$TEMP_DIR/home"
export XDG_STATE_HOME="$TEMP_DIR/state" XDG_CONFIG_HOME="$TEMP_DIR/config" XDG_RUNTIME_DIR="$TEMP_DIR/run"
unset XDG_BIN_HOME
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TEMP_DIR/bin"
STATE_DIR="$XDG_STATE_HOME/cachyos-shelly-update"
OUTPUT_FILE="$TEMP_DIR/output"

# Fake shelly, shaped like Shelly 3.x: "list-updates <source> --json" prints
# $FAKE_<SOURCE> ("name old -> new" lines) as Shelly's JSON; without --json
# it prints Shelly's human table and "nothing to do" messages, which must
# never be counted as updates. "upgrade" logs its arguments.
cat > "$TEMP_DIR/bin/shelly" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
arguments = sys.argv[1:]
if arguments == ["--version"]:
    print(os.environ.get("FAKE_SHELLY_VERSION", ""))
    sys.exit(0)
if arguments[:1] == ["list-updates"]:
    source = arguments[1]
    lines = [line.split() for line in os.environ.get(f"FAKE_{source.upper()}", "").splitlines()]
    updates = [fields for fields in lines if len(fields) == 4 and fields[2] == "->"]
    if "--json" not in arguments:
        if not updates:
            print({"aur": "All AUR packages are up to date.",
                   "appimage": "No appimage updates available"}.get(source, ""))
        else:
            print("┌──────┬───────────┬───────────┐\n│ Name │ Installed │ Available │")
            for name, old, _, new in updates:
                print(f"│ {name} │ {old} │ {new} │")
            print(f"└──────┴───────────┴───────────┘\n{len(updates)} packages can be updated")
    elif source == "appimage":
        print(json.dumps([{"Name": name, "Version": new, "IsUpdateAvailable": True}
                          for name, _, _, new in updates]
                         + [{"Name": "uptodate.AppImage", "Version": "1.0", "IsUpdateAvailable": False}]))
    else:
        print(json.dumps([{"Name": name, "Version": old, "NewVersion": new} for name, old, _, new in updates]))
    sys.exit(0)
with open(os.environ["SHELLY_LOG"], "a" if os.environ.get("SHELLY_LOG_APPEND") else "w") as log:
    log.write(" ".join(arguments) + "\n")
sys.exit(int(os.environ.get("FAKE_UPGRADE_RC", "0")))
PYEOF
# Fake checkupdates: the repositories come from $FAKE_STANDARD
cat > "$TEMP_DIR/bin/checkupdates" <<'SHEOF'
#!/bin/sh
printf '%s' "${FAKE_STANDARD:-}"
SHEOF
chmod +x "$TEMP_DIR/bin/checkupdates"
chmod +x "$TEMP_DIR/bin/shelly"
export PATH="$TEMP_DIR/bin:$PATH" SHELLY_LOG="$TEMP_DIR/shelly.log"

failureCount=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failureCount=$((failureCount + 1)); }
# expectExit "description" <expected exit code> command...
expectExit() {
    local description=$1 expectedCode=$2 exitCode=0
    shift 2
    "$@" > "$OUTPUT_FILE" 2>&1 || exitCode=$?
    if [[ $exitCode == "$expectedCode" ]]; then
        pass "$description"
    else
        fail "$description (exited $exitCode, expected $expectedCode)"
        sed 's/^/      /' "$OUTPUT_FILE"
    fi
}
# expectText "description" "text" [file]
expectText() {
    local targetFile="${3:-$OUTPUT_FILE}"
    if grep -qF -- "$2" "$targetFile"; then
        pass "$1"
    else
        fail "$1 (no '$2')"
        sed 's/^/      /' "$targetFile"
    fi
}
# expectNoText "description" "text" [file]
expectNoText() {
    if grep -qF -- "$2" "${3:-$OUTPUT_FILE}"; then fail "$1 (found '$2')"; else pass "$1"; fi
}

# ---------- options ----------
expectExit "-V exits 0" 0 "$UPDATER" -V
expectText "-V shows the version from VERSION" "cachyos-shelly-update $(cat "$REPO_ROOT/VERSION")"
expectExit "-h exits 0" 0 "$UPDATER" -h
expectText "-h shows the usage" "Usage:"
expectText "-h lists --no-appman" "--no-appman"
expectExit "unknown option exits 1" 1 "$UPDATER" --does-not-exist
expectExit "--appman (1.0 option) is still accepted" 0 "$UPDATER" -l --appman --no-flatpak

# ---------- -l with updates ----------
export FAKE_STANDARD=$'bar 2.0-1 -> 2.1-1\n' FAKE_AUR=$'foo-bin 1.0 -> 1.1\n' FAKE_APPIMAGE=''
expectExit "-l exits 0" 0 "$UPDATER" -l --no-flatpak
expectText "-l lists the repository package" "bar 2.0-1 -> 2.1-1"
expectText "-l lists the AUR package" "foo-bin 1.0 -> 1.1"
expectText "-l counts 2 updates (up-to-date AppImages are not updates)" "Available updates: 2"
expectNoText "-l shows no AppImage update when there is none" "uptodate.AppImage"
expectNoText "-l hides AppMan when it isn't installed" ":: AppMan"
if [[ ! -e $SHELLY_LOG ]]; then pass "-l doesn't call shelly upgrade"; else fail "-l called shelly upgrade"; fi
if [[ $(grep -c . "$STATE_DIR/updates_all") == 2 ]]; then pass "updates_all has 2 lines"; else fail "updates_all: $(cat "$STATE_DIR/updates_all")"; fi
FAKE_APPIMAGE=$'Tool.AppImage 1.0 -> 2.0\n' expectExit "-l with an AppImage update exits 0" 0 "$UPDATER" -l --no-flatpak
expectText "-l lists the AppImage update from Shelly's JSON" "Tool.AppImage -> 2.0"
expectText "-l counts it" "Available updates: 3"

# ---------- -c (timer) ----------
expectExit "-c exits 0" 0 "$UPDATER" -c --no-flatpak
expectText "-c saves the updates-available icon" "cachy-update_updates-available-blue" "$STATE_DIR/tray_icon"
if [[ -s $STATE_DIR/last_check ]]; then pass "-c saves last_check"; else fail "-c didn't save last_check"; fi

# ---------- -y (update) ----------
expectExit "-y exits 0" 0 "$UPDATER" -y --no-flatpak --no-devel
expectText "-y passes the right options to shelly" "-n upgrade all --no-flatpak --no-devel" "$SHELLY_LOG"
FAKE_UPGRADE_RC=1 expectExit "-y propagates a shelly failure" 1 "$UPDATER" -y --no-flatpak

# ---------- config file ----------
mkdir -p "$XDG_CONFIG_HOME/cachyos-shelly-update"
printf '# comment\n--no-aur   # no AUR\n\n' > "$XDG_CONFIG_HOME/cachyos-shelly-update/cachyos-shelly-update.conf"
expectExit "-l with a config file exits 0" 0 "$UPDATER" -l --no-flatpak
expectNoText "config --no-aur is honored" "foo-bin"
rm -f "$XDG_CONFIG_HOME/cachyos-shelly-update/cachyos-shelly-update.conf"

# ---------- AppMan ----------
# AppMan lives in ~/.local/bin (not in PATH) and keeps apps in ~/Applications.
# Each fake AM-updater touches a marker if its download part ever runs:
# checking must only run the part before [ -n "$version" ].
APPS_DIR="$HOME/Applications"
MARKER_DIR="$TEMP_DIR/markers"
export APPMAN_LOG="$TEMP_DIR/appman.log" MARKER_DIR
mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME/appman" "$MARKER_DIR"
printf 'Applications\n' > "$XDG_CONFIG_HOME/appman/appman-config"
cat > "$HOME/.local/bin/appman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$APPMAN_LOG"
exit "${FAKE_APPMAN_RC:-0}"
EOF
chmod +x "$HOME/.local/bin/appman"

# makeApp <name> <installed version> <upstream version expression>
makeApp() {
    mkdir -p "$APPS_DIR/$1"
    printf '%s\n' "$2" > "$APPS_DIR/$1/version"
    cat > "$APPS_DIR/$1/AM-updater" <<EOF
#!/bin/sh
set -u
APP=$1
SITE="example/$1"
version0=\$(cat "$APPS_DIR/\$APP/version")
version=$3
[ -n "\$version" ] || { echo "Error getting link"; exit 1; }
if [ "\$version" != "\$version0" ]; then
	touch "\$MARKER_DIR/downloaded-\$APP"
fi
EOF
    chmod +x "$APPS_DIR/$1/AM-updater"
}
makeApp outdatedapp "https://example.com/v1.2.0/OutdatedApp-1.2.0-x86_64.AppImage" \
    '"https://example.com/v1.3.0/OutdatedApp-1.3.0-x86_64.AppImage"'
makeApp currentapp "https://example.com/CurrentApp-4.0.1.AppImage" '"https://example.com/CurrentApp-4.0.1.AppImage"'
makeApp slowapp "1.0" "\$(sleep 10; echo 2.0)"
# AppMan's multi-source templates set version inside "case $SITE": one-line
# form (FreeTube) and indented form (Kdenlive)
mkdir -p "$APPS_DIR/caseapp" "$APPS_DIR/indentedapp"
printf '%s\n' "https://example.com/CaseApp-0.9.0.AppImage" > "$APPS_DIR/caseapp/version"
printf '%s\n' "https://example.com/IndentedApp-5.1.AppImage" > "$APPS_DIR/indentedapp/version"
cat > "$APPS_DIR/caseapp/AM-updater" <<EOF
#!/bin/sh
set -u
APP=caseapp
SITE="REPLACETHIS"
version0=\$(cat "$APPS_DIR/\$APP/version")
case "\$SITE" in
	"other/site") version="https://example.com/Other-1.0.AppImage";;
	*) version="https://example.com/CaseApp-1.0.0.AppImage";;
esac
[ -n "\$version" ] || { echo "Error getting link"; exit 1; }
touch "\$MARKER_DIR/downloaded-\$APP"
EOF
cat > "$APPS_DIR/indentedapp/AM-updater" <<EOF
#!/bin/sh
set -u
APP=indentedapp
SITE="REPLACETHIS"
version0=\$(cat "$APPS_DIR/\$APP/version")
case "\$SITE" in
	*)
	version="https://example.com/IndentedApp-5.2.AppImage"
	;;
esac
[ -n "\$version" ] || { echo "Error getting link"; exit 1; }
touch "\$MARKER_DIR/downloaded-\$APP"
EOF
# Doesn't follow AppMan's template: skipped, never run
mkdir -p "$APPS_DIR/customapp"
cat > "$APPS_DIR/customapp/AM-updater" <<'EOF'
#!/bin/sh
touch "$MARKER_DIR/downloaded-customapp"
EOF

export FAKE_STANDARD='' FAKE_AUR='' FAKE_APPIMAGE=''
startTime=$(date +%s)
CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "-l with AppMan apps exits 0" 0 "$UPDATER" -l --no-flatpak
elapsedSeconds=$(( $(date +%s) - startTime ))
expectText "-l shows an AppMan section" ":: AppMan"
expectText "-l lists the outdated AppMan app with short versions" "outdatedapp 1.2.0 -> 1.3.0"
expectText "-l handles the one-line \"case \$SITE\" template" "caseapp 0.9.0 -> 1.0.0"
expectText "-l handles the indented \"case \$SITE\" template" "indentedapp 5.1 -> 5.2"
expectNoText "-l doesn't list the up-to-date AppMan app" "currentapp"
expectNoText "-l skips an AM-updater that doesn't follow the template" "customapp"
expectNoText "-l skips an app whose check times out" "slowapp"
if ((elapsedSeconds < 10)); then pass "the probe timeout stops a slow check (${elapsedSeconds}s)"; else fail "slow check not stopped (${elapsedSeconds}s)"; fi
expectText "-l counts the AppMan updates" "Available updates: 3"
if [[ -z $(ls -A "$MARKER_DIR") ]]; then pass "checking AppMan never runs the download part"; else fail "download part ran: $(ls "$MARKER_DIR")"; fi
if [[ ! -e $APPMAN_LOG ]]; then pass "-l doesn't call appman"; else fail "-l called appman: $(cat "$APPMAN_LOG")"; fi
# Regression: the timed-out probe's leftover "sleep 10" used to inherit the
# lock, and every run after it failed with "already running"
expectExit "a timed-out AppMan check doesn't keep the lock" 0 "$UPDATER" -l --no-flatpak --no-appman

rm -f "$SHELLY_LOG"
CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "-y with only AppMan updates exits 0" 0 "$UPDATER" -y --no-flatpak
expectText "-y runs appman -u" "-u" "$APPMAN_LOG"
if [[ ! -e $SHELLY_LOG ]]; then pass "-y skips shelly when only AppMan has updates"; else fail "-y called shelly: $(cat "$SHELLY_LOG")"; fi

rm -f "$APPMAN_LOG"
FAKE_APPMAN_RC=1 CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "-y propagates an appman failure" 1 "$UPDATER" -y --no-flatpak

rm -f "$APPMAN_LOG"
expectExit "--no-appman exits 0" 0 "$UPDATER" -y --no-flatpak --no-appman
expectNoText "--no-appman hides the AppMan section" ":: AppMan"
if [[ ! -e $APPMAN_LOG ]]; then pass "--no-appman doesn't call appman"; else fail "--no-appman called appman"; fi

CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "-c with AppMan apps exits 0" 0 "$UPDATER" -c --no-flatpak
expectText "-c saves AppMan updates to updates_appman" "outdatedapp 1.2.0 -> 1.3.0" "$STATE_DIR/updates_appman"

# AppMan installed but never set up (no appman-config): skipped quietly
rm -f "$XDG_CONFIG_HOME/appman/appman-config"
expectExit "-l with AppMan not set up exits 0" 0 "$UPDATER" -l --no-flatpak
expectNoText "-l hides AppMan when it isn't set up" ":: AppMan"

# ---------- up to date ----------
expectExit "-l with no updates exits 0" 0 "$UPDATER" -l --no-flatpak
expectText "-l reports the system is up to date" "System is up to date"
expectExit "-c with no updates exits 0" 0 "$UPDATER" -c --no-flatpak
expectText "-c saves the \"up to date\" icon" "cachy-update-blue" "$STATE_DIR/tray_icon"

# ---------- cleanup after the update (through Shelly and AppMan) ----------
# Shelly 3.4.1 can clean; every shelly call is kept in the log
export FAKE_SHELLY_VERSION=3.4.1 SHELLY_LOG_APPEND=1
rm -f "$SHELLY_LOG" "$APPMAN_LOG"
expectExit "up to date: cleanup offered, AUR cache yes" 0 "$UPDATER" --no-flatpak < <(printf 'y\n')
expectText "purges orphans and the cache, keeping 1 version, plus the AUR cache" \
    "purify standard --orphans --cache=1 --aur-cache" "$SHELLY_LOG"
expectNoText "no Flatpak cleanup when Flatpak is off" "purify flatpak" "$SHELLY_LOG"
rm -f "$SHELLY_LOG"
expectExit "up to date: AUR cache no (default)" 0 "$UPDATER" --no-flatpak < <(printf '\n')
expectText "purify without the AUR cache" "purify standard --orphans --cache=1" "$SHELLY_LOG"
expectNoText "the AUR cache is kept" "--aur-cache" "$SHELLY_LOG"
rm -f "$SHELLY_LOG"
expectExit "no terminal: cleanup exits 0" 0 "$UPDATER" --no-flatpak < /dev/null
expectNoText "no terminal: the AUR cache is kept" "--aur-cache" "$SHELLY_LOG"
rm -f "$SHELLY_LOG"
expectExit "--no-aur: cleanup without the AUR question" 0 "$UPDATER" --no-flatpak --no-aur < /dev/null
expectNoText "--no-aur: not asked about the AUR cache" "AUR build cache"
rm -f "$SHELLY_LOG"
expectExit "--no-repo --no-aur: no purify standard" 0 "$UPDATER" --no-flatpak --no-repo --no-aur < /dev/null
if [[ ! -e $SHELLY_LOG ]]; then pass "--no-repo --no-aur: shelly purify not run"; else fail "ran: $(cat "$SHELLY_LOG")"; fi
rm -f "$SHELLY_LOG"
expectExit "--no-cleanup exits 0" 0 "$UPDATER" --no-cleanup < <(printf 'y\n')
if [[ ! -e $SHELLY_LOG ]]; then pass "--no-cleanup runs no cleanup"; else fail "--no-cleanup ran: $(cat "$SHELLY_LOG")"; fi
expectExit "-y exits 0" 0 "$UPDATER" -y --no-flatpak
expectText "-y shows the cleanup commands" "shelly purify standard --orphans --cache=1 --aur-cache"
if [[ ! -e $SHELLY_LOG ]]; then pass "-y runs no cleanup"; else fail "-y ran: $(cat "$SHELLY_LOG")"; fi
FAKE_SHELLY_VERSION=3.0.3 expectExit "old Shelly: exits 0" 0 "$UPDATER" --no-flatpak < /dev/null
expectText "old Shelly: says it needs 3.2.0" "needs 3.2.0 or newer"
if [[ ! -e $SHELLY_LOG ]]; then pass "old Shelly: no purify"; else fail "old Shelly ran: $(cat "$SHELLY_LOG")"; fi
FAKE_STANDARD=$'bar 2.0-1 -> 2.1-1\n' expectExit "update with Shelly 3.4.1 exits 0" 0 "$UPDATER" --no-flatpak < <(printf 'y\n\n')
expectText "the upgrade leaves the cache to the cleanup" "-n upgrade all --no-flatpak --disable-cache-clean" "$SHELLY_LOG"
expectText "then the cleanup runs" "purify standard --orphans --cache=1" "$SHELLY_LOG"

# AppMan set up again: its clean is asked about (default yes)
printf 'Applications\n' > "$XDG_CONFIG_HOME/appman/appman-config"
rm -f "$SHELLY_LOG" "$APPMAN_LOG"
CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "AppMan clean: yes" 0 "$UPDATER" --no-flatpak --no-repo --no-aur < <(printf 'y\n\n')
expectText "AppMan clean runs appman -c" "-c" "$APPMAN_LOG"
rm -f "$APPMAN_LOG"
CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT=2 expectExit "AppMan clean: no" 0 "$UPDATER" --no-flatpak --no-repo --no-aur < <(printf 'y\nn\n')
expectNoText "AppMan clean declined" "-c" "$APPMAN_LOG"
rm -f "$XDG_CONFIG_HOME/appman/appman-config" "$SHELLY_LOG" "$APPMAN_LOG"

# The installer's choice (a "sources" file in the install prefix) limits everything
INSTALLED_DIR="$TEMP_DIR/opt"
mkdir -p "$INSTALLED_DIR/bin"
cp "$UPDATER" "$INSTALLED_DIR/bin/"
cp -r "$REPO_ROOT/src/shellyupdate" "$INSTALLED_DIR/bin/"
printf 'repo\nappimage\n' > "$INSTALLED_DIR/sources"
FAKE_AUR=$'foo-bin 1.0 -> 1.1\n' expectExit "picked sources: -l exits 0" 0 "$INSTALLED_DIR/bin/cachyos-shelly-update" -l
expectNoText "picked sources: AUR isn't checked" "foo-bin"
expectNoText "picked sources: no AUR section" ":: AUR"
expectExit "picked sources: cleanup exits 0" 0 "$INSTALLED_DIR/bin/cachyos-shelly-update" < /dev/null
expectNoText "picked sources: no AUR cache question without AUR" "AUR build cache"
expectText "picked sources: purify for the repositories" "purify standard --orphans --cache=1" "$SHELLY_LOG"
unset FAKE_SHELLY_VERSION SHELLY_LOG_APPEND
rm -f "$SHELLY_LOG"

# ---------- lock ----------
exec 9>"$XDG_RUNTIME_DIR/cachyos-shelly-update.lock"
flock -n 9
expectExit "-c with another instance running skips without error" 0 "$UPDATER" -c --no-flatpak
CACHYOS_SHELLY_UPDATE_LOCK_TIMEOUT=1 expectExit "-l gives up after waiting for another instance" 1 "$UPDATER" -l --no-flatpak
expectText "-l says it is waiting for the background check" "Waiting for the background check to finish"
exec 9>&-

# ---------- install.sh (the interface only, nothing is installed) ----------
expectExit "install.sh --help exits 0" 0 bash "$INSTALLER" --help
expectText "install.sh --help lists the commands" "install.sh uninstall"
expectText "install.sh --help explains --purge" "--purge"
expectExit "install.sh without a command exits 1" 1 bash "$INSTALLER"
expectExit "install.sh unknown option exits 1" 1 bash "$INSTALLER" --does-not-exist
if ((EUID == 0)); then
    # CI containers run as root: with nothing installed there is nothing to rebuild
    expectExit "install.sh rebuild-venv with nothing installed exits 0" 0 bash "$INSTALLER" rebuild-venv
else
    expectExit "install.sh rebuild-venv refuses to run without root" 1 bash "$INSTALLER" rebuild-venv
fi

echo
if ((failureCount)); then echo "$failureCount test(s) failed"; exit 1; fi
echo "all tests passed"
