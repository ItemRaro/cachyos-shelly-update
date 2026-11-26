#!/usr/bin/env bash
#
# Self-update test: every earlier release, installed the way it installed
# itself, must update to the current tree through its OWN "install.sh update"
# and end up exactly like a fresh install of the current tree.
#
# The releases come from git history (each commit on the first-parent chain
# that changed VERSION), so a new release is covered without editing this
# file. Each one is extracted with "git archive", its install.sh is pointed at
# a fake root (/opt, /usr/local and /etc become $ROOT/...), and the real
# scripts run end to end: the old "install" lays out the old version, then
# the old "update" clones a git repository holding the current tree and runs
# its install.sh, as it does on a real system. Fakes stand in for sudo,
# pacman, systemctl, setsid and the network; pip is replaced by a logger
# (venvs are real, built --without-pip). pgrep/pkill only ever see processes
# this test started.
#
# Checks, for every release:
#   - the file tree (paths, modes, contents) equals a fresh install, with the
#     state files in /opt (REPO, declined-tools, cachy-update records) kept
#   - the venv is built when missing and kept when requirements.txt and
#     Python didn't change; rebuilt when either changed (current tree)
#   - systemd user units reloaded and the timer restarted
#   - the running tray (1.x or 2.x process) is stopped and the new one is
#     started in the old tray's session environment
#   - the updated command runs, and reads the old state files
# Plus the launcher (venv Python, fallback to python3), stale-file removal
# through the manifest, and (as root) restarting a user's tray from sudo.
#
# Needs git history (CI: GIT_DEPTH 0), bash, python3, procps. As root it
# creates a throwaway user and runs the main part as that user, since the
# installer runs as a normal user. Run it in a container:
#   bash tests/self_update.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SELF="$REPO_ROOT/tests/self_update.sh"
TEST_USER=csupdatetest
# The repository may belong to another user (CI checkout, bind mount)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

TEMP_DIR="$(mktemp -d)"
chmod 755 "$TEMP_DIR"
cleanup() {
    local pid
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < <(cat "$TEMP_DIR/our-pids" 2>/dev/null)
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

ROOT="$TEMP_DIR/root"            # the fake /
PREFIX_DIR="$ROOT/opt/cachyos-shelly-update"
HOME_DIR="$TEMP_DIR/home"
FAKE_BIN="$TEMP_DIR/bin"
CALL_LOG="$TEMP_DIR/calls.log"
SETSID_LOG="$TEMP_DIR/setsid.log"
OUTPUT_FILE="$TEMP_DIR/output"
NEW_REPO="$TEMP_DIR/new-repo"    # git repository with the current tree
REAL_PYTHON="$(command -v python3)"
REAL_PGREP="$(command -v pgrep)"
NEW_VERSION="$(cat "$REPO_ROOT/VERSION")"

failureCount=0
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok    %s\n' "$description"
    else
        printf 'FAIL  %s\n' "$description"
        [[ -s $OUTPUT_FILE ]] && sed 's/^/      /' "$OUTPUT_FILE"
        failureCount=$((failureCount + 1))
    fi
}
not()       { ! "$@"; }
called()    { grep -qF -- "$1" "$CALL_LOG" 2>/dev/null; }
outputHas() { grep -qF -- "$1" "$OUTPUT_FILE"; }

# ---------- fakes ----------
makeFakes() {
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$CALL_LOG"
[[ \${1:-} == -v ]] && exit 0
if [[ \${1:-} == -u ]]; then
    targetUser=\$2
    shift 2
    # As root, really switch (like sudo -u); as a user there's nothing to switch to
    if ((EUID == 0)) && [[ \$targetUser != "\$(id -un)" ]]; then
        exec runuser -u "\$targetUser" -- env "\$@"
    fi
fi
exec env "\$@"
EOF
    # Everything is installed; nothing in the repositories needs adding
    cat > "$FAKE_BIN/pacman" <<EOF
#!/usr/bin/env bash
echo "pacman \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$FAKE_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALL_LOG"
case " \$* " in
    *" is-enabled "*) echo disabled; exit 1 ;;
    *" is-active "*)  echo inactive; exit 3 ;;
esac
exit 0
EOF
    # Records the command and the environment it would have started the tray with
    cat > "$FAKE_BIN/setsid" <<EOF
#!/usr/bin/env bash
{ echo "setsid \$*"; env | sort; echo "--"; } >> "$SETSID_LOG"
EOF
    cat > "$FAKE_BIN/flatpak" <<'EOF'
#!/usr/bin/env bash
[[ $1 == remotes ]] && echo flathub
exit 0
EOF
    printf '#!/bin/sh\necho "yay v12"\n' > "$FAKE_BIN/yay"
    printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/appman"
    # python3: "-m venv" builds a real venv without pip and puts a logging
    # fake pip in it (no PyQt6 download); everything else is the real python3
    cat > "$FAKE_BIN/python3" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == -m && \${2:-} == venv ]]; then
    echo "python3 -m venv \${*:3}" >> "$CALL_LOG"
    "$REAL_PYTHON" -m venv --without-pip "\${@:3}" || exit 1
    venvDir="\${!#}"
    printf '#!/bin/sh\necho "pip \$*" >> "%s"\n' "$CALL_LOG" > "\$venvDir/bin/pip"
    chmod 755 "\$venvDir/bin/pip"
    exit 0
fi
exec "$REAL_PYTHON" "\$@"
EOF
    # pgrep/pkill limited to the processes this test started (never a real tray)
    cat > "$FAKE_BIN/pgrep" <<EOF
#!/usr/bin/env bash
found=1
while read -r pid; do
    grep -qxF "\$pid" "$TEMP_DIR/our-pids" 2>/dev/null && { echo "\$pid"; found=0; }
done < <("$REAL_PGREP" "\$@")
exit \$found
EOF
    cat > "$FAKE_BIN/pkill" <<EOF
#!/usr/bin/env bash
echo "pkill \$*" >> "$CALL_LOG"
pids=\$("$FAKE_BIN/pgrep" "\$@") || exit 1
kill \$pids
EOF
    chmod 755 "$FAKE_BIN"/*
    # A process whose command line looks like a tray's (argv[0] = $1)
    cat > "$TEMP_DIR/dummy-tray" <<'EOF'
#!/usr/bin/env bash
exec -a "$1" sleep 300
EOF
    chmod 755 "$TEMP_DIR/dummy-tray"
}

# rootInstaller <install.sh> <output>: point every absolute path constant at
# $ROOT. Works for every release: they all set their paths in VAR=/... lines.
rootInstaller() {
    sed -e "s#^\(\(readonly \)\{0,1\}[A-Z_]*=\)/#\1$ROOT/#" "$1" > "$2"
    chmod 755 "$2"
}

# runAsUser <command...>: like a user's shell, with the fakes first on PATH
runAsUser() {
    env -u DISPLAY -u WAYLAND_DISPLAY \
        HOME="$HOME_DIR" USER="$(id -un)" PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        XDG_STATE_HOME="$HOME_DIR/.local/state" XDG_RUNTIME_DIR="$TEMP_DIR/run" \
        "$@" < /dev/null > "$OUTPUT_FILE" 2>&1
}

# startDummyTray "<command line>" [VAR=value ...]: a sleeping process that
# looks like a tray to pgrep -f; its pid in $dummyPid. The subshell reaps it.
startDummyTray() {
    local commandLine=$1
    shift
    rm -f "$TEMP_DIR/dummy.pid"
    ( env -i PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$HOME_DIR" "$@" \
          "$TEMP_DIR/dummy-tray" "$commandLine" &
      echo $! > "$TEMP_DIR/dummy.pid"
      wait ) 2>/dev/null &
    while [[ ! -s $TEMP_DIR/dummy.pid ]]; do sleep 0.05; done
    dummyPid="$(cat "$TEMP_DIR/dummy.pid")"
    echo "$dummyPid" >> "$TEMP_DIR/our-pids"
}
isRunning() { [[ -r /proc/$1/stat ]] && [[ $(cut -d' ' -f3 "/proc/$1/stat") != Z ]]; }
# The tray start is a background job of the installer: give it a moment
waitForSetsid() {
    local attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        [[ -s $SETSID_LOG ]] && return 0
        sleep 0.1
    done
    return 1
}
setsidHas() { waitForSetsid && grep -qxF -- "$1" "$SETSID_LOG"; }

# A listing of the fake root: path, type, mode, content hash or link target.
# Bytecode is listed by name only (it embeds source mtimes).
snapshot() {
    (cd "$ROOT" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r path; do
        if [[ -L $path ]]; then
            printf '%s -> %s\n' "$path" "$(readlink "$path")"
        elif [[ -d $path ]]; then
            printf '%s/ %s\n' "$path" "$(stat -c %a "$path")"
        elif [[ $path == *.pyc ]]; then
            printf '%s %s\n' "$path" "$(stat -c %a "$path")"
        else
            printf '%s %s %s\n' "$path" "$(stat -c %a "$path")" "$(sha256sum < "$path" | cut -c1-16)"
        fi
    done)
}

# State an earlier install would have left in /opt and in the user's home
seedState() {
    mkdir -p "$PREFIX_DIR/cachy-update-backup" "$HOME_DIR/.local/state/cachyos-shelly-update"
    printf 'flatpak\n' > "$PREFIX_DIR/declined-tools"
    printf 'pacman-contrib\n' > "$PREFIX_DIR/installed-packages"
    printf 'user-timer\nautostart-override\nautostart-backup\n' > "$PREFIX_DIR/disabled-cachy-update"
    printf '[Desktop Entry]\nName=mine\n' > "$PREFIX_DIR/cachy-update-backup/arch-update-tray.desktop"
    # 1.0's state files: no updates_appman yet
    local stateDir="$HOME_DIR/.local/state/cachyos-shelly-update"
    printf 'linux 6.1-1 -> 6.2-1\nmesa 1-1 -> 2-1\n' > "$stateDir/updates_repo"
    printf 'yay 12-1 -> 13-1\n' > "$stateDir/updates_aur"
    : > "$stateDir/updates_flatpak"; : > "$stateDir/updates_appimage"
    cat "$stateDir/updates_repo" "$stateDir/updates_aur" > "$stateDir/updates_all"
    cp "$stateDir/updates_all" "$stateDir/notified"
    echo 1700000000 > "$stateDir/last_check"
    echo cachy-update_updates-available-blue > "$stateDir/tray_icon"
}

resetSystem() {
    rm -rf "$ROOT" "$HOME_DIR" "$CALL_LOG" "$SETSID_LOG" "$TEMP_DIR/run"
    # /usr/local/bin always exists on a real system; installers only link into it
    mkdir -p "$ROOT/usr/local/bin" "$HOME_DIR" "$TEMP_DIR/run"
    chmod 700 "$TEMP_DIR/run"
    seedState
}

# Each release as "<version> <commit>", oldest first, without the current one
listReleases() {
    local commit version seen=" $NEW_VERSION "
    git -C "$REPO_ROOT" log --first-parent --format=%H -- VERSION | while read -r commit; do
        version="$(git -C "$REPO_ROOT" show "$commit:VERSION" 2>/dev/null)" || continue
        [[ $seen == *" $version "* ]] && continue
        seen+="$version "
        echo "$version $commit"
    done | tac
}

# ---------- as root: restart a user's tray from sudo, then the rest as a user ----------
if ((EUID == 0)); then
    id "$TEST_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TEST_USER" 2>/dev/null \
        || adduser -D "$TEST_USER"
    makeFakes
    mkdir -p "$HOME_DIR" "$ROOT"
    # The new tray is started as the user: let it write the log
    touch "$SETSID_LOG"
    chmod 666 "$SETSID_LOG"
    sed -e "s#^\(\(readonly \)\{0,1\}[A-Z_]*=\)/#\1$ROOT/#" \
        -e '/^readonly SUDO_COMMAND TARGET_USER$/d' -e '/^readonly TARGET_UID TARGET_HOME$/d' \
        -e '/^main "\$@"$/,$d' "$REPO_ROOT/install.sh" > "$TEMP_DIR/installer-lib.sh"
    ( runuser -u "$TEST_USER" -- env -i PATH="$FAKE_BIN:/usr/bin:/bin" WAYLAND_DISPLAY=wayland-sudo \
          "$TEMP_DIR/dummy-tray" "/opt/cachyos-shelly-update/.venv/bin/python -m shellyupdate.tray" &
      wait ) 2>/dev/null &
    # runuser forks: the tray-like process is its child, found by owner and name
    dummyPid=""
    while [[ -z $dummyPid ]]; do
        sleep 0.05
        dummyPid="$("$REAL_PGREP" -u "$TEST_USER" -f 'shellyupdate\.tray' || true)"
    done
    echo "$dummyPid" >> "$TEMP_DIR/our-pids"
    sleep 0.2
    testHome="$(getent passwd "$TEST_USER" | cut -d: -f6)"
    PATH="$FAKE_BIN:$PATH" bash -c "
        source '$TEMP_DIR/installer-lib.sh'
        SUDO_COMMAND=()
        TARGET_USER=$TEST_USER TARGET_UID=\$(id -u $TEST_USER) TARGET_HOME='$testHome'
        restartTray" > "$OUTPUT_FILE" 2>&1 || true
    check "sudo: the user's running tray is stopped" not isRunning "$dummyPid"
    check "sudo: the new tray starts as the user" called "sudo -u $TEST_USER"
    check "sudo: in the old tray's session" setsidHas "WAYLAND_DISPLAY=wayland-sudo"
    check "sudo: through the launcher" setsidHas "setsid $ROOT/usr/local/bin/cachyos-shelly-update --tray"

    echo
    echo "-- the rest runs as $TEST_USER --"
    if ! runuser -u "$TEST_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin bash "$SELF"; then
        failureCount=$((failureCount + 1))
    fi
    ((failureCount == 0)) || { echo "$failureCount failure(s)"; exit 1; }
    exit 0
fi

# ---------- as a user ----------
makeFakes
if [[ $(git -C "$REPO_ROOT" rev-parse --is-shallow-repository) == true ]]; then
    echo "The repository is a shallow clone: the old releases aren't there (CI: set GIT_DEPTH to 0)." >&2
    exit 1
fi

# The current tree (with uncommitted changes) as the git repository updates come from
mkdir -p "$NEW_REPO"
(cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "$NEW_REPO")
rootInstaller "$REPO_ROOT/install.sh" "$NEW_REPO/install.sh"
git -C "$NEW_REPO" init --quiet
git -C "$NEW_REPO" add -A
git -C "$NEW_REPO" -c user.name=test -c user.email=test@example.com commit --quiet -m current

# ---------- baseline: a fresh install of the current tree ----------
resetSystem
runAsUser env CACHYOS_SHELLY_UPDATE_REPO="$NEW_REPO" bash "$NEW_REPO/install.sh" install \
    || { echo "fresh install failed:"; cat "$OUTPUT_FILE"; exit 1; }
snapshot > "$TEMP_DIR/fresh.snapshot"
check "fresh: installs $NEW_VERSION" test "$(cat "$PREFIX_DIR/VERSION")" == "$NEW_VERSION"
check "fresh: writes the manifest" test -s "$PREFIX_DIR/installed-files"
check "fresh: builds the venv" called "pip install"

# ---------- every release -> current ----------
mapfile -t releases < <(listReleases)
((${#releases[@]})) || { echo "no earlier releases found in git history" >&2; exit 1; }
for release in "${releases[@]}"; do
    read -r oldVersion oldCommit <<<"$release"
    label="$oldVersion -> $NEW_VERSION"
    resetSystem
    oldTree="$TEMP_DIR/old-$oldVersion"
    rm -rf "$oldTree"; mkdir -p "$oldTree"
    git -C "$REPO_ROOT" archive "$oldCommit" | tar -x -C "$oldTree"
    rootInstaller "$oldTree/install.sh" "$oldTree/install.sh.rooted"
    mv -f "$oldTree/install.sh.rooted" "$oldTree/install.sh"

    # The old version installs itself, remembering the repository to update from
    if ! runAsUser env CACHYOS_SHELLY_UPDATE_REPO="$NEW_REPO" bash "$oldTree/install.sh" install -y; then
        check "$label: the old version installs" false
        continue
    fi
    check "$label: the old version is installed" test "$(cat "$PREFIX_DIR/VERSION")" == "$oldVersion"
    rm -rf "$oldTree"            # the clone is gone: update works from /opt
    if [[ -f $PREFIX_DIR/lib/cachyos-shelly-update-tray.py ]]; then
        trayCommand="/usr/bin/python3 $PREFIX_DIR/lib/cachyos-shelly-update-tray.py"
    else
        trayCommand="$PREFIX_DIR/.venv/bin/python -m shellyupdate.tray"
    fi
    hadVenv=0
    [[ -f $PREFIX_DIR/.venv/.requirements.sha256 ]] && hadVenv=1
    startDummyTray "$trayCommand" WAYLAND_DISPLAY=wayland-test XDG_CURRENT_DESKTOP=KDE \
        PYTHONPATH=/old/lib CACHYOS_SHELLY_UPDATE_BIN=/old/bin
    oldTrayPid=$dummyPid
    sleep 0.2
    rm -f "$CALL_LOG" "$SETSID_LOG"

    # The update, by the installed old install.sh (no display: run from a TTY)
    runAsUser bash "$PREFIX_DIR/install.sh" update || true
    check "$label: updated to $NEW_VERSION" test "$(cat "$PREFIX_DIR/VERSION" 2>/dev/null)" == "$NEW_VERSION"
    snapshot > "$TEMP_DIR/updated.snapshot"
    if diff -u "$TEMP_DIR/fresh.snapshot" "$TEMP_DIR/updated.snapshot" > "$TEMP_DIR/snapshot.diff"; then
        check "$label: same files as a fresh install, state kept" true
    else
        cp "$TEMP_DIR/snapshot.diff" "$OUTPUT_FILE"
        check "$label: same files as a fresh install, state kept" false
    fi
    if ((hadVenv)); then
        check "$label: venv kept (same requirements and Python)" not called "pip install"
    else
        check "$label: venv built (the old version had none)" called "pip install"
    fi
    check "$label: user units reloaded" called "systemctl --user daemon-reload"
    check "$label: timer restarted" called "systemctl --user restart cachyos-shelly-update.timer"
    check "$label: old tray stopped" not isRunning "$oldTrayPid"
    check "$label: new tray started" setsidHas "setsid $ROOT/usr/local/bin/cachyos-shelly-update --tray"
    check "$label: in the old tray's session" setsidHas "WAYLAND_DISPLAY=wayland-test"
    check "$label: without the old tray's code paths" not setsidHas "PYTHONPATH=/old/lib"
    runAsUser "$ROOT/usr/local/bin/cachyos-shelly-update" -V
    check "$label: the updated command runs" outputHas "cachyos-shelly-update $NEW_VERSION"
    runAsUser "$PREFIX_DIR/.venv/bin/python" -I -S -c "
import sys; sys.path.insert(0, '$PREFIX_DIR/lib')
from shellyupdate import core
print('count', core.countUpdates(core.SOURCE_KEYS), core.readLines('tray_icon')[0])"
    check "$label: reads the old state files" outputHas "count 3 cachy-update_updates-available-blue"
done

# ---------- the current version updating itself (future updates) ----------
resetSystem
runAsUser env CACHYOS_SHELLY_UPDATE_REPO="$NEW_REPO" bash "$NEW_REPO/install.sh" install
rm -f "$CALL_LOG"
runAsUser bash "$NEW_REPO/install.sh" install
check "reinstall: venv kept" not called "pip install"

# requirements.txt changed (the venv records its hash)
echo stale > "$PREFIX_DIR/.venv/.requirements.sha256"
rm -f "$CALL_LOG"
runAsUser bash "$NEW_REPO/install.sh" install
check "requirements.txt changed: venv rebuilt" called "pip install"

# Python moved to another minor version
rm -f "$PREFIX_DIR/.venv/bin/python"
printf '#!/bin/sh\necho 3.0\n' > "$PREFIX_DIR/.venv/bin/python"
chmod 755 "$PREFIX_DIR/.venv/bin/python"
rm -f "$CALL_LOG"
runAsUser bash "$NEW_REPO/install.sh" install
check "Python changed: venv rebuilt" called "pip install"
check "Python changed: the venv's python is real again" test -L "$PREFIX_DIR/.venv/bin/python"

# A file the previous version installed and this one doesn't, and a damaged entry
staleFile="$ROOT/usr/local/share/applications/cachyos-shelly-update-old.desktop"
foreignFile="$ROOT/usr/local/bin/someone-elses-tool"
touch "$staleFile" "$foreignFile"
printf '%s\n%s\n' "$staleFile" "$foreignFile" >> "$PREFIX_DIR/installed-files"
runAsUser bash "$NEW_REPO/install.sh" install
check "manifest: a file no longer installed is removed" test ! -e "$staleFile"
check "manifest: a path that isn't ours is left alone" test -e "$foreignFile"
check "manifest: and reported" outputHas "left alone: $foreignFile"
check "manifest: rewritten" not grep -qF "$staleFile" "$PREFIX_DIR/installed-files"
rm -f "$foreignFile"

# ---------- the launcher: venv Python, system python3 as the fallback ----------
launcher="$ROOT/usr/local/bin/cachyos-shelly-update"
venvPython="$PREFIX_DIR/.venv/bin/python"
rm -f "$venvPython"
printf '#!/bin/sh\necho "venv python $*" >> "%s"\nexec "%s" "$@"\n' "$CALL_LOG" "$REAL_PYTHON" > "$venvPython"
chmod 755 "$venvPython"
rm -f "$CALL_LOG"
runAsUser "$launcher" -V
check "launcher: runs on the venv's python" called "venv python -I -S -c"
check "launcher: works" outputHas "cachyos-shelly-update $NEW_VERSION"
rm -f "$venvPython"
ln -s /nonexistent/python3.99 "$venvPython"
runAsUser "$launcher" -V
check "launcher: falls back to python3 when the venv's python is gone" outputHas "cachyos-shelly-update $NEW_VERSION"
rm -rf "$PREFIX_DIR/.venv"
runAsUser "$launcher" -V
check "launcher: and when there's no venv at all" outputHas "cachyos-shelly-update $NEW_VERSION"
runAsUser bash "$PREFIX_DIR/install.sh" status
check "status: says the updater fell back to python3" outputHas "updater Python: system python3"

echo
if ((failureCount)); then echo "$failureCount test(s) failed"; exit 1; fi
echo "all tests passed (${#releases[@]} releases: ${releases[*]%% *})"
