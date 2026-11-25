# cachyos-shelly-update

> 🇺🇸 [English version](../../README.md)

Atualizador no estilo do [cachy-update](https://github.com/CachyOS/cachy-update) / [arch-update](https://github.com/Antiz96/arch-update) que usa o **[Shelly](https://github.com/Seafoam-Labs/Shelly-ALPM)** como backend e também atualiza os aplicativos do **[AppMan](https://github.com/ivan-hc/AM)**. Repositórios, AUR, Flatpak, AppImage e AppMan num comando só, com verificação automática e ícone na bandeja.

## O que ele faz

- **`cachyos-shelly-update`** lista as atualizações separadas por origem, pergunta, roda `shelly upgrade all` e depois `appman -u`. Em seguida mostra os `.pacnew` pendentes e os pacotes órfãos, e avisa se o kernel mudou.
- **Verificação automática**: um timer do systemd roda `cachyos-shelly-update --check` 2 min após o login e depois a cada 6 h. Quando surge atualização nova, aparece uma notificação.
- **Bandeja**: usa os mesmos ícones do cachy-update e respeita o `TrayIconStyle` do `arch-update.conf`.
  - Clique esquerdo abre o atualizador no terminal.
  - Clique direito mostra as atualizações por origem, a última e a próxima verificação, e as opções "Check for updates" e "Quit".

As mensagens do programa são em inglês; os atalhos do menu e da bandeja aparecem em português.

### AppMan

O AppMan não tem um comando "só verificar": o `appman -u` já baixa tudo. Para listar as atualizações do AppMan sem aplicar, o cachyos-shelly-update roda só a primeira parte do script `AM-updater` de cada app, a que lê a versão instalada e pergunta a última versão para a origem, e para antes do download. Isso funciona com os scripts gerados pelos modelos do AppMan (hoje, 10.204 dos 10.206 apps do catálogo). Apps com scripts fora desse padrão ficam fora da lista, mas continuam sendo atualizados pelo `appman -u`. Cada verificação tem limite de 30 segundos (`CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT`).

O AppMan é ignorado quando não está instalado ou nunca foi configurado (sem `~/.config/appman/appman-config`). Use `--no-appman` para desligá-lo.

## Instalação

```bash
git clone <url-deste-repo> cachyos-shelly-update
cd cachyos-shelly-update
./install.sh install
```

Rode como **usuário normal**: o script pede o `sudo` quando precisa, e o `yay` e o AppMan não rodam como root.

O instalador:

1. Verifica ou instala as dependências: `shelly`, `shelly-flatpak-backend`, `flatpak`, `python`, `pacman-contrib`, `libnotify` e `curl`, além das ferramentas que o AppMan usa para descompactar apps (`wget`, `unzip`, `7zip`, `binutils`, `file`, `xz`; opcionais).
   Primeiro procura nos repositórios (o CachyOS já tem o Shelly). Se um pacote não estiver lá e o **yay** estiver instalado, usa a versão `-bin` do AUR. Pacotes que só *fornecem* a dependência, como o `shelly-bin`, também contam.
2. Instala o **AppMan** em `~/.local/bin/appman` se você não tiver, do mesmo jeito que o instalador oficial dele. Ele não é configurado: o primeiro `appman -i <app>` pergunta onde guardar os apps.
3. Copia os arquivos para **`/opt/cachyos-shelly-update`**. A instalação não depende do repositório, então o clone pode ser apagado depois.
4. Cria um virtualenv Python próprio em `/opt/cachyos-shelly-update/.venv` com a dependência da bandeja (PyQt6, fixada no `requirements.txt`), sem instalar nada no Python do sistema. Um hook do pacman reconstrói o virtualenv quando o pacote `python` muda de versão.
5. Cria o link `/usr/local/bin/cachyos-shelly-update`, o atalho no menu de aplicativos, o autostart da bandeja e o timer do systemd de usuário.
6. Desliga o cachy-update, para não ficar com dois ícones na bandeja e duas verificações: o timer dele (do usuário ou de todos os usuários), a bandeja no login e a bandeja que estiver rodando. O pacote e os arquivos dele não são mexidos; a bandeja é desligada para o seu usuário com um arquivo `~/.config/autostart/arch-update-tray.desktop` contendo `Hidden=true` (se você já tinha esse arquivo, ele é guardado). O que estava ligado fica registrado.

## Atualizar e remover

```bash
/opt/cachyos-shelly-update/install.sh update              # baixa a versão nova do git e reinstala
/opt/cachyos-shelly-update/install.sh uninstall           # remove (as dependências continuam)
/opt/cachyos-shelly-update/install.sh uninstall --purge   # também apaga seu estado/config e oferece
                                                          # remover os pacotes e o AppMan que ele instalou
/opt/cachyos-shelly-update/install.sh status              # versão, dependências, virtualenv, timer e bandeja
```

O `update` usa a URL do `origin` gravada na instalação. Para trocar a origem, rode com `CACHYOS_SHELLY_UPDATE_REPO=<url>`. Se você rodar o `update` de dentro de um clone, ele faz `git pull` e reinstala.

A remoção sempre apaga o virtualenv junto com o resto de `/opt/cachyos-shelly-update`. Se o cachy-update estava ligado antes da instalação, ela pergunta se é para religá-lo (padrão: sim) e restaura exatamente o que estava ligado, inclusive o seu arquivo de autostart. Com `--purge`, ela também oferece remover o que o instalador adicionou: só os pacotes que ele mesmo instalou (cada um fica se outro pacote ainda precisar dele) e o AppMan, se foi ele que baixou. Os apps que você instalou com o AppMan nunca são mexidos.

`-y` / `--yes` responde tudo automaticamente (o pacman e o yay recebem `--noconfirm`).

## Uso

| Comando | Descrição |
|---|---|
| `cachyos-shelly-update` | lista, pergunta e atualiza |
| `cachyos-shelly-update -l` | só lista |
| `cachyos-shelly-update -y` | atualiza sem perguntar |
| `cachyos-shelly-update -c` | verificação silenciosa (a que o timer usa) |
| `cachyos-shelly-update --tray` | inicia o ícone da bandeja |
| `--no-repo` `--no-aur` `--no-flatpak` `--no-appimage` `--no-appman` `--no-devel` | pulam origens |

Para deixar opções fixas, crie `~/.config/cachyos-shelly-update/cachyos-shelly-update.conf` com uma opção por linha. Há um exemplo em `/opt/cachyos-shelly-update/cachyos-shelly-update.conf.example`.

Para mudar o intervalo de verificação:

```bash
systemctl --user edit cachyos-shelly-update.timer
```

## Estrutura

```
install.sh                         instalar / atualizar / remover / status
VERSION                            aumente a cada release (o update compara com isto)
requirements.txt                   dependências Python da bandeja (fixadas)
src/cachyos-shelly-update          script principal (bash)
src/cachyos-shelly-update-tray.py  ícone da bandeja (PyQt6)
data/                              .desktop, unidades systemd, hook do pacman e exemplo de config
tests/                             testes rodados no CI (não mexem no sistema)
docs/pt-BR/                        documentação em português
```

## Testes e CI

O pipeline do GitLab roda em todo merge request e em todo push na `main`:

- **lint**: `shellcheck` nos scripts bash, `ruff` no Python (regras em `ruff.toml`) e validação dos `.desktop` e das unidades systemd.
- **test**: `tests/smoke.sh` roda o atualizador de verdade contra um `shelly` e um `appman` falsos, com HOME temporário e sem sudo, incluindo apps do AppMan em cada formato de modelo. `tests/cachy_update_handoff.sh` confere, com um `systemctl` falso, que a instalação desliga o cachy-update e que a remoção religa exatamente o que estava ligado. `tests/tray_smoke.py` monta a bandeja e o menu sem tela.

Para rodar localmente:

```bash
shellcheck install.sh src/cachyos-shelly-update tests/*.sh
bash tests/smoke.sh
bash tests/cachy_update_handoff.sh
ruff check .
pip install -r requirements.txt
QT_QPA_PLATFORM=offscreen python tests/tray_smoke.py
```

## Arquivos instalados

| Caminho | Conteúdo |
|---|---|
| `/opt/cachyos-shelly-update/` | programa, `install.sh`, `VERSION`, `REPO`, o virtualenv `.venv` |
| `/usr/local/bin/cachyos-shelly-update` | link para o comando |
| `/usr/local/share/applications/cachyos-shelly-update.desktop` | atalho no menu |
| `/etc/xdg/autostart/cachyos-shelly-update-tray.desktop` | bandeja ao iniciar a sessão |
| `/etc/systemd/user/cachyos-shelly-update.{service,timer}` | verificação automática |
| `/etc/pacman.d/hooks/cachyos-shelly-update-venv.hook` | reconstrói o virtualenv após atualizar o Python |
| `~/.local/bin/appman` | o AppMan, se foi o instalador que baixou |
| `~/.local/state/cachyos-shelly-update/` | estado (atualizações por origem, ícone atual) |

## Histórico de mudanças

Veja o [CHANGELOG](./CHANGELOG.md).
