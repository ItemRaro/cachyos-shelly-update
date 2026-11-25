#!/usr/bin/env python3
"""Ícone de bandeja do cachyos-shelly-update (no estilo do cachy-update).

Lê o estado gravado por `cachyos-shelly-update -c` em ~/.local/state/cachyos-shelly-update/
e usa os mesmos ícones do cachy-update. Requer python-pyqt6.
"""

import fcntl
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from PyQt6.QtCore import QFileSystemWatcher, QTimer
from PyQt6.QtGui import QAction, QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

NAME = "cachyos-shelly-update"
STATEDIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / NAME
RUNDIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
ORIGENS = [("repo", "Repositórios"), ("aur", "AUR"), ("flatpak", "Flatpak"), ("appimage", "AppImage")]
MAX_ITENS = 40  # itens por submenu


def shelly_update_bin() -> str:
    return (os.environ.get("CACHYOS_SHELLY_UPDATE_BIN")
            or shutil.which(NAME)
            or f"/opt/{NAME}/bin/{NAME}")


def ler_linhas(nome: str) -> list[str]:
    try:
        return [l for l in (STATEDIR / nome).read_text().splitlines() if l.strip()]
    except OSError:
        return []


def tempo_humano(segundos: float) -> str:
    s = int(abs(segundos))
    if s < 60:
        return "menos de 1 min"
    if s < 3600:
        return f"{s // 60} min"
    if s < 86400:
        h, m = divmod(s // 60, 60)
        return f"{h} h {m} min" if m else f"{h} h"
    d, h = divmod(s // 3600, 24)
    return f"{d} d {h} h" if h else f"{d} d"


def proxima_verificacao() -> str | None:
    """Lê do timer do systemd quando será a próxima verificação."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "show", f"{NAME}.timer",
             "-p", "NextElapseUSecRealtime", "--value"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        if not out or out == "n/a":
            return None
        # Formato: "Thu 2026-11-26 10:23:11 -03" -> descarta o dia da semana e o fuso
        partes = out.split()
        quando = datetime.strptime(f"{partes[1]} {partes[2]}", "%Y-%m-%d %H:%M:%S")
        return tempo_humano((quando - datetime.now()).total_seconds())
    except Exception:
        return None


def comando_terminal(cmd: list[str]) -> list[str] | None:
    """Monta o comando para abrir `cmd` num terminal (Konsole primeiro, por ser KDE)."""
    preferido = os.environ.get("CACHYOS_SHELLY_UPDATE_TERMINAL")
    opcoes = [
        ("konsole", ["konsole", "-e"]),
        ("kitty", ["kitty"]),
        ("alacritty", ["alacritty", "-e"]),
        ("foot", ["foot"]),
        ("wezterm", ["wezterm", "start", "--"]),
        ("ghostty", ["ghostty", "-e"]),
        ("gnome-terminal", ["gnome-terminal", "--"]),
        ("xterm", ["xterm", "-e"]),
    ]
    if preferido:
        opcoes.insert(0, (preferido, [preferido, "-e"]))
    for exe, prefixo in opcoes:
        if shutil.which(exe):
            return prefixo + cmd
    return None


class Bandeja:
    def __init__(self, app: QApplication):
        self.app = app
        self.tray = QSystemTrayIcon()
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.montar_menu)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.ao_clicar)
        self.verificando = False

        STATEDIR.mkdir(parents=True, exist_ok=True)
        # Observa a pasta de estado: o cachyos-shelly-update troca os arquivos com mv,
        # então observar a pasta é mais confiável que observar cada arquivo
        self.watcher = QFileSystemWatcher([str(STATEDIR)])
        self.watcher.directoryChanged.connect(lambda _: self.agendar_atualizacao())
        self.debounce = QTimer(singleShot=True, interval=500)
        self.debounce.timeout.connect(self.atualizar)
        # Rede de segurança caso algum evento se perca
        self.poll = QTimer(interval=60_000)
        self.poll.timeout.connect(self.atualizar)
        self.poll.start()

        self.atualizar()
        self.tray.show()

    # ---------- estado ----------
    def agendar_atualizacao(self):
        self.debounce.start()

    def nome_icone(self) -> str:
        nomes = ler_linhas("tray_icon")
        return nomes[0].strip() if nomes else "cachy-update-blue"

    def atualizar(self):
        nome = self.nome_icone()
        icone = QIcon.fromTheme(nome)
        if icone.isNull():
            # Fallback se o cachy-update não estiver instalado
            tem = bool(ler_linhas("updates_all"))
            icone = QIcon.fromTheme("update-high" if tem else "update-none",
                                    QIcon.fromTheme("system-software-update"))
        self.tray.setIcon(icone)

        total = len(ler_linhas("updates_all"))
        if self.verificando:
            dica = "Verificando atualizações..."
        elif total == 0:
            dica = "Sistema em dia"
        else:
            dica = f"{total} atualização disponível" if total == 1 else f"{total} atualizações disponíveis"
        self.tray.setToolTip(f"CachyOS-Shelly-Update\n{dica}")

    # ---------- menu ----------
    def montar_menu(self):
        m = self.menu
        m.clear()
        total = len(ler_linhas("updates_all"))

        if self.verificando:
            a = m.addAction("Verificando atualizações...")
            a.setEnabled(False)
        elif total == 0:
            a = m.addAction(QIcon.fromTheme("checkmark"), "Sistema em dia")
            a.setEnabled(False)
        else:
            txt = "1 atualização disponível" if total == 1 else f"{total} atualizações disponíveis"
            m.addAction(QIcon.fromTheme("system-software-update"), txt).triggered.connect(self.executar)

            for chave, rotulo in ORIGENS:
                itens = ler_linhas(f"updates_{chave}")
                if not itens:
                    continue
                sub = m.addMenu(f"{rotulo} ({len(itens)})")
                for item in itens[:MAX_ITENS]:
                    sub.addAction(item).setEnabled(False)
                if len(itens) > MAX_ITENS:
                    sub.addAction(f"... e mais {len(itens) - MAX_ITENS}").setEnabled(False)

        m.addSeparator()
        ultima = ler_linhas("last_check")
        if ultima:
            try:
                m.addAction(f"Última verificação há {tempo_humano(time.time() - int(ultima[0]))}").setEnabled(False)
            except ValueError:
                pass
        prox = proxima_verificacao()
        if prox:
            m.addAction(f"Próxima verificação em {prox}").setEnabled(False)

        m.addSeparator()
        m.addAction(QIcon.fromTheme("system-run"), "Executar CachyOS-Shelly-Update").triggered.connect(self.executar)
        acao_check = m.addAction(QIcon.fromTheme("view-refresh"), "Verificar atualizações")
        acao_check.setEnabled(not self.verificando)
        acao_check.triggered.connect(self.verificar)
        m.addAction(QIcon.fromTheme("application-exit"), "Sair").triggered.connect(self.app.quit)

    # ---------- ações ----------
    def ao_clicar(self, motivo):
        if motivo == QSystemTrayIcon.ActivationReason.Trigger:
            self.executar()

    def executar(self):
        cmd = comando_terminal([shelly_update_bin(), "--wait"])
        if cmd is None:
            self.tray.showMessage("CachyOS-Shelly-Update", "Nenhum terminal encontrado. Defina CACHYOS_SHELLY_UPDATE_TERMINAL.")
            return
        subprocess.Popen(cmd, start_new_session=True)

    def verificar(self):
        self.verificando = True
        self.atualizar()
        proc = subprocess.Popen([shelly_update_bin(), "--check"], start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Acompanha o fim do processo sem travar a interface
        timer = QTimer(interval=1000)

        def checar():
            if proc.poll() is not None:
                timer.stop()
                self.verificando = False
                self.atualizar()

        timer.timeout.connect(checar)
        timer.start()
        self._timer_check = timer  # mantém referência


def main():
    # Só uma bandeja por vez
    lock = open(RUNDIR / f"{NAME}-tray.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("O ícone do cachyos-shelly-update já está rodando.", file=sys.stderr)
        sys.exit(1)

    app = QApplication(sys.argv)
    app.setApplicationName("CachyOS-Shelly-Update")
    app.setDesktopFileName(NAME)
    app.setQuitOnLastWindowClosed(False)

    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("Bandeja do sistema não disponível.", file=sys.stderr)
        sys.exit(1)

    _bandeja = Bandeja(app)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
