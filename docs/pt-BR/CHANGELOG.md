# Changelog

Todas as mudanças relevantes deste projeto são documentadas neste arquivo. A
versão em inglês, com as mesmas mudanças, está em
[CHANGELOG.md](../../CHANGELOG.md).

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto usa [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [Unreleased]

## [1.1.0] - 2026-11-25

### Adicionado
- O AppMan virou uma origem de atualização completa: o timer verifica as
  atualizações dele, que aparecem por app no terminal, na notificação e num
  novo submenu "AppMan" da bandeja, e são aplicadas com `appman -u` na mesma
  execução do Shelly. A verificação roda só a consulta de versão do começo do
  `AM-updater` de cada app (nunca o download), com limite de 30 segundos por
  app (`CACHYOS_SHELLY_UPDATE_PROBE_TIMEOUT`).
- `--no-appman` para pular o AppMan.
- O instalador instala o AppMan em `~/.local/bin/appman` quando ele não
  existe, junto com as ferramentas que o AppMan usa para descompactar apps
  (`wget`, `unzip`, `7zip`, `binutils`, `file`, `xz`; opcionais).
- A dependência Python da bandeja (PyQt6) é instalada num virtualenv próprio
  em `/opt/cachyos-shelly-update/.venv`, fixada no `requirements.txt`, no
  lugar do `python-pyqt6` do sistema.
- Um hook do pacman reconstrói esse virtualenv quando o pacote `python` muda
  de versão menor (um virtualenv para de funcionar quando isso acontece).
- `install.sh uninstall --purge` oferece remover os pacotes que o instalador
  adicionou e o AppMan, se foi o instalador que baixou. Os apps instalados
  com o AppMan nunca são removidos.
- `install.sh status` mostra o AppMan e o estado do virtualenv.
- A bandeja segue o tema de ícones do KDE (`kdeglobals`), mesmo com o PyQt6
  do pip não tendo o plugin de plataforma do KDE.
- CI no GitLab: shellcheck, ruff, validação dos `.desktop` e das unidades
  systemd, e testes que rodam os scripts de verdade contra `shelly`/`appman`
  falsos.
- Documentação em inglês; a em português foi para `docs/pt-BR/`.

### Alterado
- O AppMan fica ligado por padrão quando está instalado e configurado. O
  `--appman` continua aceito, mas não muda mais nada.
- Todas as mensagens do programa, o código e os comentários estão em inglês.
  Os atalhos `.desktop` mantêm a tradução em português (`[pt_BR]`).
- Estilo do código: variáveis e funções em camelCase, classes em PascalCase,
  constantes em MAIÚSCULAS.
- O `python-pyqt6` deixou de ser dependência (trocado pelo virtualenv); o
  `python` e o `curl` passaram a ser.

### Corrigido
- A pasta temporária do comando `update` agora é sempre apagada na saída (o
  trap de limpeza guardava o caminho cedo demais).
- Avisos do shellcheck no `install.sh` e no atualizador: os comandos e as
  verificações são despachados com `case` explícitos, e as cadeias
  `A && B || C` viraram blocos `if`.

## [1.0.0] - 2026-11-25

### Adicionado
- Primeira versão: o `cachyos-shelly-update` lista, confirma e aplica as
  atualizações dos repositórios, AUR, Flatpak e AppImage pelo Shelly, e
  depois verifica `.pacnew`, órfãos e troca de kernel.
- Timer do systemd de usuário para verificar em segundo plano, com
  notificações.
- Ícone de bandeja em PyQt6 com os ícones do cachy-update.
- `install.sh` com install, update, uninstall e status.

[Unreleased]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.1.0...main
[1.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.0.0...v1.1.0
[1.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/tags/v1.0.0
