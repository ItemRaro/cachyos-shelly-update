# cachyos-shelly-update

Atualizador no estilo do [cachy-update](https://github.com/CachyOS/cachy-update) / [arch-update](https://github.com/Antiz96/arch-update), usando o **[Shelly](https://github.com/Seafoam-Labs/Shelly-ALPM)** como backend: repositórios, AUR, Flatpak e AppImage num comando só, com verificação automática e ícone na bandeja.

## O que ele faz

- **`cachyos-shelly-update`**: lista as atualizações separadas por origem, pergunta e roda `shelly upgrade all`. Depois mostra os `.pacnew`, os pacotes órfãos e avisa se o kernel mudou.
- **Verificação automática**: um timer do systemd roda `cachyos-shelly-update --check` 2 min após o login e depois a cada 6 h. Quando surge atualização nova, aparece uma notificação.
- **Bandeja**: usa os mesmos ícones do cachy-update e respeita o `TrayIconStyle` do `arch-update.conf`.
  - Clique esquerdo abre o atualizador no terminal.
  - Clique direito mostra a lista por origem, a última e a próxima verificação, e as opções "Verificar agora" e "Sair".

## Instalação

```bash
git clone <url-deste-repo> cachyos-shelly-update
cd cachyos-shelly-update
./install.sh install
```

Rode como **usuário normal**: o script pede o `sudo` quando precisa, e o `yay` não pode rodar como root.

O instalador:

1. Verifica ou instala as dependências: `shelly`, `shelly-flatpak-backend`, `flatpak`, `python-pyqt6`, `pacman-contrib` e `libnotify`.
   Primeiro procura nos repositórios (o CachyOS já tem o Shelly). Se um pacote não estiver lá e o **yay** estiver instalado, usa a versão `-bin` do AUR. Pacotes que só *fornecem* a dependência, como o `shelly-bin`, também contam.
2. Copia os arquivos para **`/opt/cachyos-shelly-update`**. A instalação não depende do repositório, então o clone pode ser apagado depois.
3. Cria o link `/usr/local/bin/cachyos-shelly-update`, o atalho no menu de aplicativos, o autostart da bandeja e o timer do systemd de usuário.
4. Se o cachy-update estiver ativo, oferece desativar o timer e a bandeja dele, para não ficar com dois ícones. O pacote dele continua instalado.

## Atualizar e remover

```bash
/opt/cachyos-shelly-update/install.sh update       # baixa a versão nova do git e reinstala
/opt/cachyos-shelly-update/install.sh uninstall    # remove (o Shelly continua instalado)
/opt/cachyos-shelly-update/install.sh uninstall --purge   # remove e apaga o estado/config do usuário
/opt/cachyos-shelly-update/install.sh status       # versão, dependências, timer e bandeja
```

O `update` usa a URL do `origin` gravada na instalação. Para trocar a origem, rode com `CACHYOS_SHELLY_UPDATE_REPO=<url>`. Se você rodar o `update` de dentro de um clone, ele faz `git pull` e reinstala.

`-y` / `--yes` responde tudo automaticamente (o pacman e o yay recebem `--noconfirm`).

## Uso

| Comando | Descrição |
|---|---|
| `cachyos-shelly-update` | lista, pergunta e atualiza |
| `cachyos-shelly-update -l` | só lista |
| `cachyos-shelly-update -y` | atualiza sem perguntar |
| `cachyos-shelly-update -c` | verificação silenciosa (a que o timer usa) |
| `cachyos-shelly-update --tray` | inicia o ícone da bandeja |
| `--no-repo` `--no-aur` `--no-flatpak` `--no-appimage` `--no-devel` | pulam origens |
| `--appman` | também roda `appman -u` |

Para deixar opções fixas, crie `~/.config/cachyos-shelly-update/cachyos-shelly-update.conf` com uma opção por linha. Há um exemplo em `/opt/cachyos-shelly-update/cachyos-shelly-update.conf.example`.

Para mudar o intervalo de verificação:

```bash
systemctl --user edit cachyos-shelly-update.timer
```

## Estrutura

```
install.sh                 instalar / atualizar / remover / status
VERSION                    aumente a cada release (o update compara com isto)
src/cachyos-shelly-update          script principal (bash)
src/cachyos-shelly-update-tray.py  ícone da bandeja (PyQt6)
data/                      .desktop, unidades systemd e exemplo de config
tests/                     testes rodados no CI (não mexem no sistema)
```

## Testes e CI

O pipeline do GitLab roda em todo merge request e em todo push na `main`:

- **lint**: `shellcheck` nos scripts bash, `ruff` no Python (regras em `ruff.toml`) e validação dos `.desktop` e das unidades systemd.
- **test**: `tests/smoke.sh` roda o atualizador de verdade contra um `shelly` falso, com HOME temporário e sem sudo. `tests/tray_smoke.py` monta a bandeja e o menu sem tela.

Para rodar localmente:

```bash
shellcheck install.sh src/cachyos-shelly-update tests/smoke.sh
bash tests/smoke.sh
ruff check .
QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py   # precisa do python-pyqt6
```

## Arquivos instalados

| Caminho | Conteúdo |
|---|---|
| `/opt/cachyos-shelly-update/` | programa, `install.sh`, `VERSION`, `REPO` |
| `/usr/local/bin/cachyos-shelly-update` | link para o comando |
| `/usr/local/share/applications/cachyos-shelly-update.desktop` | atalho no menu |
| `/etc/xdg/autostart/cachyos-shelly-update-tray.desktop` | bandeja ao iniciar a sessão |
| `/etc/systemd/user/cachyos-shelly-update.{service,timer}` | verificação automática |
| `~/.local/state/cachyos-shelly-update/` | estado (lista de updates, ícone atual) |
