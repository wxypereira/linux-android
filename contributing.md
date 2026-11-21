# Contribuindo para linux-android

Obrigado por dedicar seu tempo ao projeto! Toda contribuição é bem-vinda.

## Sumário

- [Código de conduta](#código-de-conduta)
- [Dúvidas](#tenho-uma-dúvida)
- [Quero contribuir](#quero-contribuir)
- [Sugestões de melhoria](#sugerindo-melhorias)
- [Antes de abrir um PR](#antes-de-abrir-um-pr)

## Código de conduta

Este projeto e seus participantes são regidos pelo [Código de Conduta](code-of-conduct.md). Ao participar, espera-se que você respeite esse documento.

## Tenho uma dúvida

1. Pesquise nas [issues existentes](https://github.com/wxypereira/linux-android/issues).
2. Se não houver resposta, abra uma issue com contexto suficiente.
3. Informe, quando aplicável, as versões do Termux, Termux:X11, Android e Cyberdeck.

Não use issue pública para vulnerabilidades. Consulte [security.md](security.md).

## Quero contribuir

Ao contribuir, você concorda que sua contribuição será licenciada sob a licença do projeto.

### Sugerindo melhorias

Inclua:

- título claro;
- problema e comportamento atual;
- resultado esperado;
- passos de reprodução;
- impacto e alternativas consideradas.

Use issues ou pull requests, conforme a natureza da mudança.

## Antes de abrir um PR

Execute a verificação local:

```bash
bash tests/run.sh
```

O CI também executa:

- `bash -n` nos scripts;
- ShellCheck;
- testes de contrato e geração de launchers;
- verificação de links e âncoras Markdown.

Mantenha o escopo de cada PR pequeno e inclua testes para regressões. Não edite `tickets.md`, que é um artefato local ignorado pelo Git.
