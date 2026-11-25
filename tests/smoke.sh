#!/usr/bin/env bash
#
# Smoke test do cachyos-shelly-update, sem tocar no sistema:
# um "shelly" falso no PATH, HOME/XDG_* temporários, nada de sudo/pacman.
# Roda no CI (imagem bash:5) e localmente: bash tests/smoke.sh

set -euo pipefail

RAIZ="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BIN="$RAIZ/src/cachyos-shelly-update"
INSTALL="$RAIZ/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config" XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMP/bin"
STATE="$XDG_STATE_HOME/cachyos-shelly-update"

# shelly falso: list-updates lê $FAKE_<origem>, upgrade grava os argumentos
cat > "$TMP/bin/shelly" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == list-updates ]]; then
    case $2 in
        standard) printf '%s' "${FAKE_STANDARD:-}" ;;
        aur)      printf '%s' "${FAKE_AUR:-}" ;;
        appimage) printf '%s' "${FAKE_APPIMAGE:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" > "$SHELLY_LOG"
exit "${FAKE_UPGRADE_RC:-0}"
EOF
chmod +x "$TMP/bin/shelly"
export PATH="$TMP/bin:$PATH" SHELLY_LOG="$TMP/shelly.log"

FALHAS=0
ok()    { printf 'ok    %s\n' "$1"; }
falha() { printf 'FALHA %s\n' "$1"; FALHAS=$((FALHAS + 1)); }
espera() {   # espera "descrição" <código esperado> comando...
    local desc=$1 rc_esperado=$2 rc=0; shift 2
    "$@" > "$TMP/out" 2>&1 || rc=$?
    if [[ $rc == "$rc_esperado" ]]; then ok "$desc"; else falha "$desc (saiu $rc, esperado $rc_esperado)"; sed 's/^/      /' "$TMP/out"; fi
}
contem() {   # contem "descrição" "texto" [arquivo]
    if grep -qF -- "$2" "${3:-$TMP/out}"; then ok "$1"; else falha "$1 (sem '$2')"; sed 's/^/      /' "${3:-$TMP/out}"; fi
}

# ---------- opções ----------
espera "-V sai com 0" 0 "$BIN" -V
contem "-V mostra a versão do arquivo VERSION" "cachyos-shelly-update $(cat "$RAIZ/VERSION")"
espera "-h sai com 0" 0 "$BIN" -h
contem "-h mostra o uso" "Uso:"
espera "opção desconhecida sai com 1" 1 "$BIN" --nao-existe

# ---------- -l com atualizações ----------
export FAKE_STANDARD=$'bar 2.0-1 -> 2.1-1\n' FAKE_AUR=$'foo-bin 1.0 -> 1.1\n' FAKE_APPIMAGE=$'No updates available\n'
espera "-l sai com 0" 0 "$BIN" -l --no-flatpak
contem "-l lista o pacote do repositório" "bar 2.0-1 -> 2.1-1"
contem "-l lista o pacote do AUR" "foo-bin 1.0 -> 1.1"
contem "-l conta 2 atualizações (\"No updates\" é filtrado)" "Atualizações disponíveis: 2"
if [[ ! -e $SHELLY_LOG ]]; then ok "-l não chama shelly upgrade"; else falha "-l chamou shelly upgrade"; fi
if [[ $(grep -c . "$STATE/updates_all") == 2 ]]; then ok "updates_all tem 2 linhas"; else falha "updates_all: $(cat "$STATE/updates_all")"; fi

# ---------- -c (timer) ----------
espera "-c sai com 0" 0 "$BIN" -c --no-flatpak
contem "-c grava o ícone de atualizações" "cachy-update_updates-available-blue" "$STATE/tray_icon"
if [[ -s $STATE/last_check ]]; then ok "-c grava last_check"; else falha "-c não gravou last_check"; fi

# ---------- -y (atualização) ----------
espera "-y sai com 0" 0 "$BIN" -y --no-flatpak --no-devel
contem "-y passa as opções certas ao shelly" "-n upgrade all --no-flatpak --no-devel" "$SHELLY_LOG"
FAKE_UPGRADE_RC=1 espera "-y propaga falha do shelly" 1 "$BIN" -y --no-flatpak

# ---------- config ----------
mkdir -p "$XDG_CONFIG_HOME/cachyos-shelly-update"
printf '# comentário\n--no-aur   # sem AUR\n\n' > "$XDG_CONFIG_HOME/cachyos-shelly-update/cachyos-shelly-update.conf"
espera "-l com config sai com 0" 0 "$BIN" -l --no-flatpak
if grep -qF "foo-bin" "$TMP/out"; then falha "config --no-aur ignorada"; else ok "config --no-aur é respeitada"; fi
rm -f "$XDG_CONFIG_HOME/cachyos-shelly-update/cachyos-shelly-update.conf"

# ---------- sistema em dia ----------
export FAKE_STANDARD='' FAKE_AUR='' FAKE_APPIMAGE=''
espera "-l sem atualizações sai com 0" 0 "$BIN" -l --no-flatpak
contem "-l informa sistema em dia" "Sistema atualizado"
espera "-c sem atualizações sai com 0" 0 "$BIN" -c --no-flatpak
contem "-c grava o ícone \"em dia\"" "cachy-update-blue" "$STATE/tray_icon"

# ---------- trava ----------
exec 9>"$XDG_RUNTIME_DIR/cachyos-shelly-update.lock"
flock -n 9
espera "-c com outra instância rodando pula sem erro" 0 "$BIN" -c --no-flatpak
espera "-l com outra instância rodando sai com 1" 1 "$BIN" -l --no-flatpak
exec 9>&-

# ---------- install.sh (só a interface, nada é instalado) ----------
espera "install.sh --help sai com 0" 0 bash "$INSTALL" --help
contem "install.sh --help mostra os comandos" "install.sh uninstall"
espera "install.sh sem comando sai com 1" 1 bash "$INSTALL"
espera "install.sh opção desconhecida sai com 1" 1 bash "$INSTALL" --nao-existe

echo
if ((FALHAS)); then echo "$FALHAS teste(s) falharam"; exit 1; fi
echo "todos os testes passaram"
