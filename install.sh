#!/usr/bin/env bash
#
# Instalador do cachyos-shelly-update
#
#   ./install.sh install     instala em /opt/cachyos-shelly-update (e as dependências)
#   ./install.sh update      atualiza a partir do repositório git
#   ./install.sh uninstall   remove (use --purge para apagar também o estado/config do usuário)
#   ./install.sh status      mostra o que está instalado
#
# Opções:  -y | --yes   não pergunta nada (pacman/yay com --noconfirm)
#          --purge      (uninstall) apaga ~/.local/state e ~/.config do cachyos-shelly-update
#
# Rode como seu usuário normal: o script pede o sudo quando precisa.
# (O yay não pode rodar como root.)
#
# Depois de instalado, este script fica em /opt/cachyos-shelly-update/install.sh,
# então o repositório pode ser apagado: update e uninstall funcionam de lá.

set -euo pipefail

NAME=cachyos-shelly-update
PREFIX=/opt/$NAME
BINLINK=/usr/local/bin/$NAME
APPDIR=/usr/local/share/applications
AUTOSTART=/etc/xdg/autostart
UNITDIR=/etc/systemd/user
SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Dependência -> nome no repositório | nome no AUR (para o yay)
# O "pacman -T" também aceita pacotes que fornecem a dependência (ex.: shelly-bin)
DEPS=(
    "shelly|shelly|shelly-bin"
    "shelly-flatpak-backend|shelly-flatpak-backend|shelly-flatpak-backend-bin"
    "flatpak|flatpak|"
    "python-pyqt6|python-pyqt6|"
    "pacman-contrib|pacman-contrib|"
    "libnotify|libnotify|"
)

# ---------- saída ----------
if [[ -t 1 ]]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else
    B=''; G=''; Y=''; R=''; C=''; N=''
fi
info()  { printf '%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
passo() { printf '%s  ->%s %s\n' "$C" "$N" "$*"; }
warn()  { printf '%s==> AVISO:%s %s\n' "$Y" "$N" "$*"; }
morre() { printf '%s==> ERRO:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ---------- usuário / privilégios ----------
SIM=0
PURGE=0
if ((EUID == 0)); then
    SUDO=()
    USUARIO="${SUDO_USER:-}"
else
    SUDO=(sudo)
    USUARIO="$USER"
fi
root() { "${SUDO[@]}" "$@"; }

USER_UID=""
USER_HOME=""
if [[ -n $USUARIO && $USUARIO != root ]]; then
    USER_UID="$(id -u "$USUARIO")"
    USER_HOME="$(getent passwd "$USUARIO" | cut -d: -f6)"
fi

# Roda um comando como o usuário normal, com acesso ao systemd --user dele
como_usuario() {
    [[ -n $USER_UID ]] || return 1
    if ((EUID == 0)); then
        sudo -u "$USUARIO" \
            XDG_RUNTIME_DIR="/run/user/$USER_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

confirma() {   # confirma "pergunta" [padrão S|N]
    ((SIM)) && return 0
    local resp padrao="${2:-S}"
    read -rp "$(printf '%s::%s %s [%s] ' "$C$B" "$N" "$1" "$([[ $padrao == S ]] && echo S/n || echo s/N)")" resp
    resp="${resp,,}"; [[ -z $resp ]] && resp="${padrao,,}"
    [[ $resp == s || $resp == sim || $resp == y || $resp == yes ]]
}

# ---------- dependências ----------
dep_ok()      { pacman -T "$1" >/dev/null 2>&1; }
no_repo()     { [[ -n $1 ]] && pacman -Si "$1" >/dev/null 2>&1; }
tem_yay()     { command -v yay >/dev/null 2>&1; }

garantir_deps() {
    info "Verificando dependências"
    local item dep repo aur noconf=()
    ((SIM)) && noconf=(--noconfirm)
    if tem_yay; then
        passo "yay encontrado: $(yay --version 2>/dev/null | head -1)"
    else
        passo "yay não encontrado (só os repositórios oficiais serão usados)"
    fi

    for item in "${DEPS[@]}"; do
        IFS='|' read -r dep repo aur <<<"$item"
        if dep_ok "$dep"; then
            passo "$dep: ${G}ok${N}"
            continue
        fi
        if no_repo "$repo"; then
            passo "$dep: instalando pelo pacman"
            root pacman -S --needed "${noconf[@]}" "$repo" || morre "Falha ao instalar $repo"
        elif [[ -n $aur ]] && tem_yay; then
            [[ -n $USER_UID ]] || morre "$dep precisa do yay, que não roda como root. Rode o script como seu usuário."
            passo "$dep: não está nos repositórios; instalando $aur pelo yay (AUR)"
            como_usuario yay -S --needed "${noconf[@]}" "$aur" || morre "Falha ao instalar $aur pelo yay"
        else
            morre "$dep não encontrado nos repositórios${aur:+ e o yay não está instalado para buscar $aur no AUR}."
        fi
    done
}

# ---------- arquivos ----------
instalar_arquivos() {
    info "Instalando em $PREFIX"
    [[ -f $SRC/src/$NAME ]] || morre "Arquivos do projeto não encontrados em $SRC/src (rode o install a partir do repositório)."

    root install -Dm755 "$SRC/src/$NAME"                "$PREFIX/bin/$NAME"
    root install -Dm755 "$SRC/src/$NAME-tray.py"        "$PREFIX/lib/$NAME-tray.py"
    root install -Dm644 "$SRC/VERSION"                  "$PREFIX/VERSION"
    root install -Dm644 "$SRC/data/$NAME.conf.example"  "$PREFIX/$NAME.conf.example"
    [[ $SRC == "$PREFIX" ]] || root install -Dm755 "$SRC/install.sh" "$PREFIX/install.sh"

    # Guarda de onde veio, para o "update" funcionar sem o repositório
    local url="${CACHYOS_SHELLY_UPDATE_REPO:-}"
    [[ -z $url && -d $SRC/.git ]] && url="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
    if [[ -n $url ]]; then
        printf '%s\n' "$url" | root tee "$PREFIX/REPO" >/dev/null
        passo "origem para updates: $url"
    fi

    root ln -sfn "$PREFIX/bin/$NAME" "$BINLINK"
    root install -Dm644 "$SRC/data/$NAME.desktop"       "$APPDIR/$NAME.desktop"
    root install -Dm644 "$SRC/data/$NAME-tray.desktop"  "$AUTOSTART/$NAME-tray.desktop"
    root install -Dm644 "$SRC/data/$NAME.service"       "$UNITDIR/$NAME.service"
    root install -Dm644 "$SRC/data/$NAME.timer"         "$UNITDIR/$NAME.timer"
    passo "comando: $BINLINK"
    passo "menu de aplicativos, autostart da bandeja e timer do systemd instalados"
}

ativar() {
    info "Ativando verificação automática e bandeja"
    # Timer para todos os usuários (equivale ao que o cachy-update faz)
    root systemctl --global enable "$NAME.timer" >/dev/null 2>&1 || warn "não consegui ativar o timer globalmente"

    if como_usuario systemctl --user daemon-reload 2>/dev/null; then
        como_usuario systemctl --user restart "$NAME.timer" 2>/dev/null && passo "timer iniciado"
        # Primeira verificação em segundo plano para a bandeja já ter dados
        como_usuario systemctl --user start --no-block "$NAME.service" 2>/dev/null || true
    else
        warn "Sessão do usuário não encontrada; o timer começa no próximo login."
    fi

    # (Re)inicia a bandeja na sessão gráfica atual
    if ((EUID != 0)) && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
        pkill -u "$USER" -f "$NAME-tray.py" 2>/dev/null || true
        sleep 0.5
        setsid "$BINLINK" --tray >/dev/null 2>&1 < /dev/null &
        passo "bandeja iniciada"
    else
        passo "a bandeja aparece no próximo login"
    fi
}

verificar_icones() {
    if [[ ! -e /usr/share/icons/hicolor/scalable/apps/cachy-update-blue.svg ]]; then
        warn "Ícones do cachy-update não encontrados; a bandeja vai usar ícones genéricos do tema."
        warn "Para ter os mesmos ícones: sudo pacman -S cachy-update"
    fi
}

oferecer_desativar_cachy_update() {
    local ativo=0
    como_usuario systemctl --user is-enabled arch-update.timer >/dev/null 2>&1 && ativo=1
    como_usuario systemctl --user is-enabled arch-update-tray.service >/dev/null 2>&1 && ativo=1
    pgrep -f arch-update-tray >/dev/null 2>&1 && ativo=1
    ((ativo)) || return 0

    echo
    warn "O cachy-update também está ativo (vai ficar com dois ícones e duas verificações)."
    if confirma "Desativar o timer e a bandeja do cachy-update? (o pacote continua instalado)" S; then
        root systemctl --global disable arch-update.timer arch-update-tray.service >/dev/null 2>&1 || true
        como_usuario systemctl --user disable --now arch-update.timer arch-update-tray.service >/dev/null 2>&1 || true
        [[ -n $USER_HOME ]] && rm -f "$USER_HOME"/.config/autostart/{arch,cachy}-update-tray.desktop
        pkill -f arch-update-tray 2>/dev/null || true
        passo "cachy-update desativado (reative pelo CachyOS Hello quando quiser)"
    fi
}

# ---------- comandos ----------
cmd_install() {
    command -v pacman >/dev/null || morre "Este instalador é para Arch/CachyOS (pacman não encontrado)."
    local antiga=""; [[ -f $PREFIX/VERSION ]] && antiga="$(cat "$PREFIX/VERSION")"
    info "cachyos-shelly-update $(cat "$SRC/VERSION")${antiga:+ (instalado: $antiga)}"

    ((EUID != 0)) && { sudo -v || morre "sudo necessário"; }
    garantir_deps
    instalar_arquivos
    ativar
    verificar_icones
    oferecer_desativar_cachy_update

    echo
    info "Pronto! Use '$NAME' no terminal ou clique no ícone da bandeja."
    echo "   Atualizar:  $PREFIX/install.sh update"
    echo "   Remover:    $PREFIX/install.sh uninstall"
}

cmd_update() {
    command -v git >/dev/null || morre "git não encontrado."
    ((EUID != 0)) && { sudo -v || morre "sudo necessário"; }

    # 1) Rodando de dentro de um clone do repositório: git pull e reinstala
    if [[ $SRC != "$PREFIX" && -d $SRC/.git ]]; then
        info "Atualizando o repositório em $SRC"
        if [[ -n $USER_UID ]]; then
            como_usuario git -C "$SRC" pull --ff-only || morre "git pull falhou"
        else
            git -C "$SRC" pull --ff-only || morre "git pull falhou"
        fi
        exec bash "$SRC/install.sh" install "${REPASSAR[@]}"
    fi

    # 2) Rodando de /opt: baixa a versão nova do repositório salvo na instalação
    local url="${CACHYOS_SHELLY_UPDATE_REPO:-$(cat "$PREFIX/REPO" 2>/dev/null || true)}"
    [[ -n $url ]] || morre "Não sei de onde atualizar. Rode com CACHYOS_SHELLY_UPDATE_REPO=<url-do-git> $0 update"

    # Global (não local) para o trap ainda enxergar a pasta na saída do script
    TMP_UPDATE="$(mktemp -d)"
    local tmp="$TMP_UPDATE"
    trap 'rm -rf "$TMP_UPDATE"' EXIT
    chmod 755 "$tmp"
    if [[ -n $USER_UID ]]; then
        chown "$USUARIO" "$tmp" 2>/dev/null || true
    fi

    info "Baixando $url"
    # Clona como o usuário (usa as chaves SSH/credenciais dele)
    como_usuario git clone --quiet --depth 1 "$url" "$tmp/repo" 2>/dev/null \
        || git clone --quiet --depth 1 "$url" "$tmp/repo" \
        || morre "Falha ao clonar $url"

    local atual nova
    atual="$(cat "$PREFIX/VERSION" 2>/dev/null || echo 0)"
    nova="$(cat "$tmp/repo/VERSION")"
    if [[ $atual == "$nova" ]] && ! confirma "Já está na versão $atual. Reinstalar mesmo assim?" N; then
        info "Nada a fazer."
        exit 0
    fi
    CACHYOS_SHELLY_UPDATE_REPO="$url" bash "$tmp/repo/install.sh" install "${REPASSAR[@]}"
}

cmd_uninstall() {
    info "Removendo o cachyos-shelly-update"
    ((EUID != 0)) && { sudo -v || morre "sudo necessário"; }

    if [[ -n $USUARIO ]]; then
        pkill -u "$USUARIO" -f "$NAME-tray.py" 2>/dev/null || true
        como_usuario systemctl --user disable --now "$NAME.timer" >/dev/null 2>&1 || true
    fi
    root systemctl --global disable "$NAME.timer" >/dev/null 2>&1 || true

    root rm -f "$BINLINK" "$APPDIR/$NAME.desktop" "$AUTOSTART/$NAME-tray.desktop" \
               "$UNITDIR/$NAME.service" "$UNITDIR/$NAME.timer"
    root rm -rf "$PREFIX"
    como_usuario systemctl --user daemon-reload >/dev/null 2>&1 || true
    passo "arquivos removidos"

    if ((PURGE)) && [[ -n $USER_HOME ]]; then
        rm -rf "$USER_HOME/.local/state/$NAME" "$USER_HOME/.config/$NAME"
        passo "estado e configuração do usuário apagados"
    fi

    echo
    info "cachyos-shelly-update removido."
    echo "   O Shelly e as outras dependências continuam instalados."
    echo "   Para voltar ao cachy-update: CachyOS Hello > Apps/Tweaks > Cachy Update"
}

cmd_status() {
    local v="não instalado"; [[ -f $PREFIX/VERSION ]] && v="$(cat "$PREFIX/VERSION")"
    info "cachyos-shelly-update: $v"
    [[ -f $PREFIX/REPO ]] && passo "origem: $(cat "$PREFIX/REPO")"

    info "Dependências"
    local item dep repo aur
    for item in "${DEPS[@]}"; do
        IFS='|' read -r dep repo aur <<<"$item"
        if dep_ok "$dep"; then passo "$dep: ${G}ok${N}"; else passo "$dep: ${R}faltando${N}"; fi
    done
    if tem_yay; then passo "yay: ${G}ok${N}"; else passo "yay: não instalado"; fi

    info "Serviços"
    passo "timer: $(como_usuario systemctl --user is-active "$NAME.timer" 2>/dev/null || echo inativo)"
    if pgrep -f "$NAME-tray.py" >/dev/null; then passo "bandeja: rodando"; else passo "bandeja: parada"; fi
}

# ---------- main ----------
main() {
    local cmd=""
    REPASSAR=()
    while (($#)); do
        case "$1" in
            install|update|uninstall|status) cmd="$1" ;;
            -y|--yes)  SIM=1; REPASSAR+=(-y) ;;
            --purge)   PURGE=1 ;;
            -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) morre "Opção desconhecida: $1 (veja $0 --help)" ;;
        esac
        shift
    done
    case "$cmd" in
        install)   cmd_install ;;
        update)    cmd_update ;;
        uninstall) cmd_uninstall ;;
        status)    cmd_status ;;
        *) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
}

# Tudo dentro de main: o bash lê a função inteira antes de executar,
# então o uninstall pode apagar este próprio arquivo sem problemas
main "$@"
exit
