# Changelog

Todas as alterações relevantes do repositório são registradas neste arquivo.

## v1.4.0 — 2026-11-20

### Adicionado

- distro Debian Bookworm ARM64 real via `proot-distro`, com imagem fixada por digest;
- flow de instalação host/guest separado: Termux:X11/PulseAudio no Termux e desktop/aplicativos no Debian;
- suporte a XFCE4, LXQt, MATE e KDE Plasma com matriz única de validação;
- detecção de GPU com Freedreno, Panfrost, Zink e fallback `llvmpipe`;
- lock exclusivo de instalação com `flock`;
- launchers `~/start-linux.sh` e `~/stop-linux.sh` com PIDs próprios, readiness e cleanup limitado à sessão;
- wrapper do usuário `~/.local/bin/cyberdeck-wine`;
- suíte de testes Bash, mocks e CI com ShellCheck e verificação de links.

### Modificado

- scripts passaram a falhar imediatamente em erros de pacote, Git ou PRoot;
- o bootstrap valida worktree, remote canônico e SHA-256 do script interno;
- a seleção de desktop passou a ser estritamente validada;
- a geração de launchers preserva arquivos anteriores com backup versionado;
- a documentação passou a refletir a implementação real e os limites do PRoot.

### Removido

- `tur-repo` (o Termux:X11 continua vindo do pacote oficial `termux-x11-nightly` do repositório `x11-repo`);
- instalação global de Flask;
- symlink global de Wine em `/usr/bin`;
- necessidade de `termux-setup-storage` e de desativar restrições globais de processos filhos;
- alegações de isolamento ou “risco zero”.

---

## v1.3

### Adicionado

- `contributing.md`;
- `code-of-conduct.md`.

## v1.2

### Adicionado

- política de segurança.

## v1.1

### Adicionado

- `changelog.md`;
- `LICENSE`.

### Modificado

- `README.md` passou a incluir uma seção de FAQ.
