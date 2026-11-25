"""Smoke test da bandeja, sem tela (QT_QPA_PLATFORM=offscreen).

Cria arquivos de estado falsos, monta a bandeja e o menu de verdade e
confere o que aparece. Roda no CI e localmente:
    QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
"""

import os
import runpy
import sys
import tempfile
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
tmp = Path(tempfile.mkdtemp())
os.environ["XDG_STATE_HOME"] = str(tmp / "state")
os.environ["XDG_RUNTIME_DIR"] = str(tmp / "run")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
(tmp / "run").mkdir()

state = tmp / "state" / "cachyos-shelly-update"
state.mkdir(parents=True)
(state / "updates_repo").write_text("bar 2.0-1 -> 2.1-1\n")
(state / "updates_aur").write_text("foo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\n")
(state / "updates_all").write_text("bar 2.0-1 -> 2.1-1\nfoo-bin 1.0 -> 1.1\nbaz-git r1 -> r2\n")
(state / "last_check").write_text(f"{int(time.time()) - 600}\n")

m = runpy.run_path(str(RAIZ / "src" / "cachyos-shelly-update-tray.py"), run_name="ci")

falhas = []


def confere(desc, cond):
    print(("ok    " if cond else "FALHA ") + desc)
    if not cond:
        falhas.append(desc)


# Funções puras
th = m["tempo_humano"]
confere("tempo_humano(30)", th(30) == "menos de 1 min")
confere("tempo_humano(600)", th(600) == "10 min")
confere("tempo_humano(3600)", th(3600) == "1 h")
confere("tempo_humano(5400)", th(5400) == "1 h 30 min")
confere("tempo_humano(2 dias)", th(2 * 86400) == "2 d")
confere("ler_linhas ignora linhas vazias", m["ler_linhas"]("updates_aur") == ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"])
confere("ler_linhas de arquivo inexistente", m["ler_linhas"]("nao_existe") == [])

# Bandeja e menu de verdade
app = m["QApplication"](sys.argv)
bandeja = m["Bandeja"](app)
confere("tooltip mostra o total", "3 atualizações disponíveis" in bandeja.tray.toolTip())

bandeja.montar_menu()
textos = [a.text() for a in bandeja.menu.actions()]
submenus = {a.text(): [s.text() for s in a.menu().actions()] for a in bandeja.menu.actions() if a.menu()}
print("      menu:", textos)
confere("menu mostra o total", "3 atualizações disponíveis" in textos)
confere("submenu Repositórios (1)", submenus.get("Repositórios (1)") == ["bar 2.0-1 -> 2.1-1"])
confere("submenu AUR (2)", submenus.get("AUR (2)") == ["foo-bin 1.0 -> 1.1", "baz-git r1 -> r2"])
confere("sem submenu para origem vazia", not any(t.startswith("Flatpak") for t in textos))
confere("última verificação", "Última verificação há 10 min" in textos)
confere("ações fixas", {"Executar CachyOS-Shelly-Update", "Verificar atualizações", "Sair"} <= set(textos))

# Sistema em dia
for f in ("updates_repo", "updates_aur", "updates_all"):
    (state / f).write_text("")
bandeja.atualizar()
bandeja.montar_menu()
textos = [a.text() for a in bandeja.menu.actions()]
confere("em dia: tooltip", "Sistema em dia" in bandeja.tray.toolTip())
confere("em dia: menu", "Sistema em dia" in textos)

print()
if falhas:
    print(f"{len(falhas)} teste(s) falharam")
    sys.exit(1)
print("todos os testes passaram")
