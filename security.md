# Política de Segurança

Valorizamos a segurança do **Cyberdeck: Linux no Android**. Se você encontrar uma vulnerabilidade, reporte-a de forma privada para que o projeto possa corrigi-la antes da divulgação pública.

## Versões suportadas

| Versão | Recebe correções de segurança |
| :--- | :--- |
| Versão mais recente (`master`) | Sim |
| Versões anteriores | Não |

## Canal privado de reporte

**Não abra uma issue pública para relatar uma vulnerabilidade explorável.**

Use o GitHub Private Vulnerability Reporting:

1. Abra <https://github.com/wxypereira/linux-android/security/advisories/new>;
2. descreva o impacto, os passos de reprodução e as versões afetadas;
3. aguarde a confirmação privada antes de publicar qualquer detalhe.

Se **Private Vulnerability Reporting** não estiver disponível para sua conta,
solicite um canal privado ao mantenedor pelo perfil
[@wxypereira](https://github.com/wxypereira) — **sem detailing técnico no
primeiro contato**.

O primeiro contato deve conter apenas:

- resumo sem payload público;
- impacto;
- versão do Termux, Termux:X11 e Android;
- pedido de um canal privado para os detalhes técnicos.

Os detalhes técnicos (passos de reprodução, payloads, exfiltração) só devem
ser enviados depois que um canal privado for confirmado pelos mantenedores.

Não inclua exploit pronto, credenciais, tokens ou dados pessoais — nem em
issue, nem em mensagem direta.

## O que pode ser discutido publicamente

- Bugs de segurança sem impacto explorável podem ser discutidos em issue normal.
- Correções e advisories podem ser publicados depois que a versão corrigida estiver disponível.
- Vulnerabilidades críticas ou que exponham dados do usuário devem permanecer privadas até a coordenação do disclose.

## Limites de isolamento

O Cyberdeck usa PRoot para executar uma distro Linux sem `root`. Isso isola o filesystem da distro, mas **não** cria um sandbox contra malware:

- programas no guest podem acessar a internet;
- o guest usa as permissões concedidas ao aplicativo Termux;
- dados presentes no diretório Termux podem ser acessados pelo processo executado no guest;
- PRoot não isola o kernel Android.

Não execute conteúdo de terceiros dentro do guest sem revisar o código e entender esse modelo de ameaça.

## Boas práticas

- use somente o repositório canônico <https://github.com/wxypereira/linux-android>;
- confira o resultado do instalador e os logs antes de continuar;
- mantenha Termux e Termux:X11 atualizados;
- revise atualizações e scripts antes de executá-los em dispositivos com dados sensíveis;
- relate falhas de integridade ou comportamento inesperado pelo canal privado.
