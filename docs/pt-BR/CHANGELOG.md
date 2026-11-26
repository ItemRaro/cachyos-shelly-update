# Changelog

Todas as mudanças relevantes deste projeto são documentadas neste arquivo. A
versão em inglês, com as mesmas mudanças, está em
[CHANGELOG.md](../../CHANGELOG.md).

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto usa [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [Unreleased]

## [2.1.0] - 2026-11-25

### Corrigido
- O ícone da bandeja mostrava sempre "updates available", e uma entrada
  AppImage vazia aparecia no menu: a saída do Shelly é uma tabela formatada,
  e os cabeçalhos, bordas e mensagens dela (como "No appimage updates
  available") eram contados como atualizações. As verificações de AUR e
  AppImage agora leem `shelly list-updates ... --json`, e os AppImages só
  contam quando o Shelly marca `IsUpdateAvailable`.
- Começar uma atualização durante uma verificação em segundo plano falhava
  com "already running"; agora ela espera a verificação (até 5 minutos).

### Alterado
- O menu da bandeja é o do cachy-update, com contagens no lugar das listas
  de pacotes: o total, uma entrada "Origem (N)" por origem com atualizações,
  a última e a próxima verificação no formato "1h 5m", e depois Run, Check
  for updates e Exit. O `ShowTrayWhenRelevant` do `arch-update.conf` esconde
  o ícone quando está tudo em dia. "Repositories" virou "Packages", como no
  cachy-update.
- O timer verifica a cada hora (antes, 6 horas). Nenhuma verificação pega a
  trava do pacman: o fallback do Shelly para os repositórios, que
  sincronizava os bancos de verdade, saiu; o `checkupdates` é sempre usado.
- O instalador pergunta antes de instalar o que falta, em vez de exigir ou
  instalar sem avisar: yay (pelos repositórios, ou `yay-bin` do AUR), Flatpak
  com o backend de Flatpak do Shelly e o Flathub, e o AppMan. Um "não" fica
  guardado até a remoção. O Flatpak deixou de ser dependência obrigatória; o
  atualizador o pula quando não está instalado.
- As perguntas do instalador aparecem mesmo quando as respostas vêm por pipe.

## [2.0.0] - 2026-11-25

### Alterado
- O atualizador foi reescrito em Python (só biblioteca padrão, rodando no
  `python3` do sistema); o `install.sh` continua em bash. Comandos, opções,
  arquivo de configuração, arquivos de estado, unidades systemd e bandeja
  são os mesmos, então uma instalação 1.x atualiza sem mudanças.
- O CLI e a bandeja usam um pacote só (`shellyupdate`): origens, arquivos de
  estado, textos e ícones são definidos uma vez.
- As origens são verificadas em paralelo, e os apps do AppMan 8 por vez. As
  chamadas do Shelly continuam uma depois da outra. Com atrasos parecidos com
  os da rede, uma verificação caiu de 7,6 s para 2,1 s num benchmark; com
  origens instantâneas, as duas levam cerca de 0,1 s.
- O código é pré-compilado na instalação, e o hook do pacman o recompila
  depois de atualizações do Python.

### Adicionado
- A bandeja abre o atualizador no emulador de terminal padrão do usuário: o
  configurado no KDE Plasma, o `xdg-terminal-exec`, o `$TERMINAL` ou o
  `x-terminal-emulator`, antes de uma lista de terminais conhecidos. O
  `CACHYOS_SHELLY_UPDATE_TERMINAL` continua tendo prioridade.
- Testes de unidade do pacote (`tests/test_units.py`), junto com os testes
  de fumaça da 1.x, que continuam rodando sem mudanças contra o código novo.

### Corrigido
- A bandeja abria o primeiro terminal que encontrava (ex.: Alacritty), e não
  o configurado como padrão (ex.: Ghostty).
- Uma verificação do AppMan que estoura o tempo agora encerra também o que
  ela iniciou (um `curl` travado), e não só o shell dela.

## [1.2.0] - 2026-11-25

### Alterado
- A instalação desliga o cachy-update sem perguntar (duas bandejas e duas
  verificações iam competir) e registra o que estava ligado: o timer dele,
  do usuário ou de todos os usuários, a bandeja no login e a bandeja
  rodando.
- A remoção pergunta se é para religar o cachy-update quando ele estava
  ligado antes da instalação, e restaura exatamente isso, inclusive o
  `~/.config/autostart/arch-update-tray.desktop` do próprio usuário.
- `install.sh status` mostra se o cachy-update foi desligado pelo
  instalador.

### Corrigido
- A bandeja do cachy-update voltava no próximo login: o pacote do CachyOS a
  inicia por `/etc/xdg/autostart/arch-update-tray.desktop`, que o instalador
  não tratava. Agora ela é desligada para o usuário com um override XDG
  (`Hidden=true`), sem mexer nos arquivos do pacote.
- O instalador não tenta mais desativar o `arch-update-tray.service`, que o
  cachy-update não tem.

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

[Unreleased]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v2.1.0...main
[2.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v2.0.0...v2.1.0
[2.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.2.0...v2.0.0
[1.2.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.1.0...v1.2.0
[1.1.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/compare/v1.0.0...v1.1.0
[1.0.0]: https://shiva.ddns.net/marcusvinicius/cachyos-shelly-update/-/tags/v1.0.0
