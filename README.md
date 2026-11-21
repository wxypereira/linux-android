# Cyberdeck: Linux no Android

<div align="center">

![GitHub repo size](https://img.shields.io/github/repo-size/wxypereira/linux-android?style=for-the-badge&color=8A2BE2)
![GitHub language count](https://img.shields.io/github/languages/count/wxypereira/linux-android?style=for-the-badge&color=8A2BE2)
![GitHub forks](https://img.shields.io/github/forks/wxypereira/linux-android?style=for-the-badge&color=8A2BE2)
![GitHub issues](https://img.shields.io/github/issues/wxypereira/linux-android?style=for-the-badge&color=8A2BE2)

<img src="image.png" alt="Cyberdeck Banner" width="100%">

> *Cyberdecks são computadores portáteis personalizados inspirados em ficção científica, cultura hacker e estética cyberpunk.*

</div>

---

## Índice

- [Sobre o projeto](#sobre-o-projeto)
- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Instalação](#instalação)
- [Ambientes gráficos](#ambientes-gráficos-suportados)
- [Inicialização](#inicialização)
- [GPU](#seleção-de-gpu)
- [Wine](#wine)
- [Segurança](#segurança)
- [Solução de problemas](#solução-de-problemas)
- [Contribuição](#contribuição)

---

## Sobre o projeto

O Cyberdeck transforma um dispositivo Android ARM64 em uma estação de trabalho Linux portátil. O ambiente Linux real é uma distribuição **Debian Bookworm** instalada em uma distro PRoot pelo `proot-distro`.

A divisão de responsabilidades é intencional:

- **Host Termux:** Termux:X11, PulseAudio, `proot-distro` e o ciclo de vida da sessão.
- **Guest Debian:** desktop, terminal, navegador Epiphany, VLC, ferramentas de desenvolvimento e Wine.

O projeto não usa `root` e não substitui o Android. A distro guest fica no armazenamento privado do Termux e é removível.

---

## Arquitetura

```text
App Termux:X11 no Android
          │
          ▼
Termux:X11 + PulseAudio (host)
          │
          ▼
proot-distro / Debian Bookworm ARM64 (guest)
          │
          ├── XFCE4, LXQt, MATE ou KDE Plasma
          ├── Epiphany, VLC e ferramentas CLI
          └── Wine para aplicativos Windows compatíveis
```

A imagem guest é fixada pelo digest:

```text
debian:bookworm-slim@sha256:ec8534cda2cb30f29f44f23e135297af7a1496f2990fd8e4e84aa36b081a757a
```

O `script-installation.sh` também valida por SHA-256 o `script-termux.sh` executado dentro da distro canônica.

> **Importante:** PRoot não é um sandbox contra malware. Um programa executado no guest ainda pode acessar a internet e os recursos permitidos ao Termux. Veja [Segurança](#segurança).

---

## Pré-requisitos

- Android com dispositivo **ARM64**;
- Termux instalado pelo [F-Droid](https://f-droid.org/packages/com.termux/) ou por uma [release oficial do Termux](https://github.com/termux/termux-app/releases);
- Termux:X11 instalado pelo [F-Droid](https://f-droid.org/packages/com.termux.x11/) ou pela [release oficial do Termux:X11](https://github.com/termux/termux-x11/releases);
- Git instalado no Termux (`pkg install git`) — é necessário **antes** do `git clone`;
- espaço livre recomendado:
  - XFCE4: **3,5 GB**;
  - LXQt: **3 GB**;
  - MATE: **4 GB**;
  - KDE Plasma: **6 GB**.

O instalador verifica o espaço antes de alterar o ambiente. O valor inclui margem para o índice de pacotes e a imagem da distro.

---

## Instalação

### 1. Instale o Git e clone o repositório canônico

```bash
pkg install git
git clone https://github.com/wxypereira/linux-android.git
cd linux-android
```

> O `git clone` exige o Git instalado no Termux. O instalador também instala o
> Git para uso interno, mas o clone acontece **antes** dele — por isso o passo
> acima é obrigatório.

### 2. Execute o instalador

Escolha um desktop:

```bash
bash script-installation.sh xfce4
```

Também são aceitos:

```bash
bash script-installation.sh --desktop=lxqt
bash script-installation.sh --desktop mate
bash script-installation.sh --desktop=kde
```

Opções válidas:

- `xfce4`;
- `lxqt`;
- `mate`;
- `kde`.

Sem argumento, o instalador usa `xfce4`. Um valor inválido faz o comando terminar com erro; não há fallback silencioso para outro desktop.

O instalador:

1. verifica o espaço em disco (antes de qualquer alteração no ambiente);
2. atualiza o Termux e instala Git;
3. obtém o repositório canônico em `~/linux-android`;
4. valida origem, worktree e SHA-256 do script interno;
5. instala as dependências do host e a distro Debian pinada;
6. instala o desktop e os aplicativos dentro da distro;
7. cria os launchers `~/start-linux.sh` e `~/stop-linux.sh`;
8. cria o wrapper `~/.local/bin/cyberdeck-wine`;
9. executa validações antes de declarar sucesso.

> **Unidade de release:** o `script-installation.sh` fixa por SHA-256 o
> `script-termux.sh` do mesmo release. Se o repositório canônico publicar uma
> versão nova do script interno, a atualização é **abortada antes** do merge
> (o checkout não é alterado) e o instalador informa como atualizar o
> wrapper. Isso impede executar um script interno diferente do digest
> esperado.

Logs são gravados em `$PREFIX/var/log/cyberdeck` no Termux.

> O processo de instalação pode demorar bastante na primeira execução, pois a imagem Debian e os pacotes do desktop são baixados dentro da distro.

---

## Ambientes gráficos suportados

| Ambiente | Consumo estimado | Recomendação |
| --- | --- | --- |
| **XFCE4** | 3,5 GB | Recomendado para uso geral. |
| **LXQt** | 3 GB | Melhor para dispositivos com menos memória. |
| **MATE** | 4 GB | Alternativa tradicional e estável. |
| **KDE Plasma** | 6 GB | Use em dispositivos modernos. |

---

## Inicialização

1. Abra o aplicativo **Termux:X11** no Android.
2. No Termux, execute:

```bash
~/start-linux.sh
```

O launcher:

- adquire um lock exclusivo de sessão (`~/.cyberdeck/session.lock`) e recusa uma segunda inicialização concorrente, sem sobrescrever os registros da sessão ativa;
- inicia ou reutiliza somente o PulseAudio da sessão;
- habilita o transporte de áudio para o guest: módulo TCP do PulseAudio **limitado a `127.0.0.1`** e protegido por cookie (`~/.cyberdeck/pulse/cookie`), validado antes de abrir o desktop;
- inicia o Termux:X11 com autenticação X, sem `-ac`;
- aguarda o socket e a prontidão do display com timeout;
- inicia o desktop dentro da distro Debian, com a home do Termux compartilhada (`--shared-home`);
- persiste os PIDs próprios da sessão **com o start time** (`/proc/<pid>/stat`), evitando confundir um PID reutilizado pelo kernel com um processo da sessão.

Para encerrar a sessão:

```bash
~/stop-linux.sh
```

O encerramento envia `TERM`, aguarda e só então usa `KILL` para processos próprios que ainda estejam vivos **e cuja identidade (PID + start time) ainda confere**. O projeto não usa `pkill` global.

Para iniciar o desktop automaticamente ao abrir o Termux, adicione ao final de `~/.bashrc`:

```bash
~/start-linux.sh
```

---

## Seleção de GPU

A detecção usa `ro.hardware.egl`, `ro.hardware.vulkan` e `ro.board.platform`:

| GPU detectada | Driver primário | Fallback |
| --- | --- | --- |
| Adreno / Qualcomm | `freedreno` | `llvmpipe` |
| Mali / Panfrost | `panfrost` | `llvmpipe` |
| Genérica | `zink` | `llvmpipe` |

A escolha é persistida em `~/.cyberdeck/gpu.conf`. A aceleração depende do dispositivo, do kernel Android e do Termux:X11; o fallback em software é uma medida de estabilidade, não uma garantia de desempenho.

---

## Wine

O Wine é instalado dentro da distro Debian ARM64. Não há symlink global em `/usr/bin` e nenhum arquivo gerenciado pelo APT é sobrescrito.

Use o wrapper do usuário:

```bash
~/.local/bin/cyberdeck-wine caminho/do/programa.exe
```

O wrapper abre uma sessão do PRoot com o X11 e o áudio da sessão atual
(`--shared-x11`, `--shared-home`, `DISPLAY`, `XAUTHORITY`, `PULSE_SERVER` e
`PULSE_COOKIE`). Caminhos relativos são resolvidos no host e traduzidos para
o caminho visível no guest, com bind do diretório quando necessário — assim
`cyberdeck-wine ./jogo.exe` executa o arquivo correto.

Se `~/.local/bin` não estiver no `PATH`, use o caminho completo ou adicione o diretório ao `PATH`.

---

## Segurança

- O fluxo não solicita acesso ao armazenamento compartilhado do Android.
- O fluxo não exige desativar a proteção global de processos filhos do Android.
- PRoot melhora o isolamento do filesystem, mas **não** protege contra programas maliciosos.
- Guest e host compartilham a identidade do usuário Termux e as permissões concedidas a ele.
- Não execute scripts de terceiros dentro da distro sem revisar seu conteúdo.
- O bootstrap valida a origem do repositório e a integridade SHA-256 do script interno.

Para reportar uma vulnerabilidade, use **GitHub Private Vulnerability Reporting** em `Security` → `Report a vulnerability`. Não publique exploits ou detalhes confidenciais em issue pública. Veja [security.md](security.md).

---

## Solução de problemas

### A instalação informa que outro processo está em execução

O instalador usa um lock exclusivo por usuário. Aguarde a outra instalação terminar. Se o processo anterior foi interrompido de forma anormal, confirme que ele não está mais ativo antes de remover o lock em:

```text
$PREFIX/var/lock/cyberdeck-install.lock
```

### O Termux:X11 não abre a sessão

Confirme que:

- o aplicativo Termux:X11 está instalado;
- `~/start-linux.sh` terminou sem erro;
- nenhum outro servidor X está usando o display `:0`;
- o log em `$PREFIX/var/log/cyberdeck` não mostra falha de readiness.

### O desktop inicia com erros gráficos

Consulte `~/.cyberdeck/gpu.conf`. O launcher tenta o driver primário e, se a sessão falhar, uma vez o fallback `llvmpipe`.

### A distro guest ficou incompleta

Rode o instalador novamente. Ele reutiliza a distro `cyberdeck`, atualiza os índices do guest e executa as validações finais. Para recomeçar do zero:

```bash
proot-distro remove cyberdeck
bash script-installation.sh xfce4
```

---

## Contribuição

Leia [contributing.md](contributing.md) e [code-of-conduct.md](code-of-conduct.md). Execute a suíte local antes de abrir um PR:

```bash
bash tests/run.sh
```

Issues e PRs:

- <https://github.com/wxypereira/linux-android/issues>
- <https://github.com/wxypereira/linux-android/pulls>

## Licença

Este projeto está sob a licença correspondente ao repositório. Veja [LICENSE](LICENSE).
