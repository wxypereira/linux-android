#!/usr/bin/env bash
# ==========================================================================
#  Cyberdeck: Linux no Android - Script de Instalação Externa (Termux Host)
# ==========================================================================
#  Este script é o entrypoint chamado pelo usuário no host Termux.
#  Responsabilidades:
#    - Bootstrap do host (git, clone/update do repositório canônico)
#    - Validação de integridade (SHA-256) do script interno
#    - Canonicalização do parâmetro --desktop (aceita --desktop=valor e posicional)
#    - Invocação NÃO INTERATIVA do script interno via caminho absoluto
#    - Logs persistentes em $PREFIX/var/log/cyberdeck
#
#  CONTRATO COM O SCRIPT INTERNO (script-termux.sh):
#    - Este wrapper é o dono do lock de instalação (LOCK_FILE) e o repassa ao
#      script interno com --lock-held, evitando lock duplicado.
#    - O script interno honra --lock-held: não tenta adquirir o lock de novo.
#    - O SHA-256 abaixo é o digest concreto do script-termux.sh deste release;
#      ele é validado antes de executar o script interno (e tests/run.sh
#      garante que o digest e o arquivo continuam sincronizados).
# ==========================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constantes e Configuração
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CYBERDECK_REPO_URL_DEFAULT="https://github.com/wxypereira/linux-android"
readonly CYBERDECK_REPO_URL="${CYBERDECK_REPO_URL:-${CYBERDECK_REPO_URL_DEFAULT}}"
readonly CYBERDECK_SCRIPT_SHA256="f8163329f4b2a9014a490abf18160b050e7d3fcdc9af4a58cf67e0cc06541fd3"  # SHA-256 do script interno no release
readonly INTERNAL_SCRIPT_NAME="script-termux.sh"
readonly VALID_DESKTOPS=("xfce4" "lxqt" "mate" "kde")
readonly DEFAULT_DESKTOP="xfce4"

# Espaço mínimo (MiB) por desktop — mesma tabela do script interno.
# A verificação ocorre ANTES de qualquer mutação de pacotes.
declare -A DESKTOP_SPACE_MIB=(
    [xfce4]=3500
    [lxqt]=3000
    [mate]=4000
    [kde]=6000
)
LOCK_FILE="${PREFIX:-${HOME}/.termux}/var/lock/cyberdeck-install.lock"
LOCK_FD=""
# Diretório de destino padrão absoluto (permite override via CYBERDECK_REPO_DIR)
readonly CYBERDECK_REPO_DIR_DEFAULT="${HOME}/linux-android"
readonly CYBERDECK_REPO_DIR="${CYBERDECK_REPO_DIR:-${CYBERDECK_REPO_DIR_DEFAULT}}"

# Diretório de logs: preferir $PREFIX/var/log/cyberdeck, fallback seguro
if [[ -n "${PREFIX:-}" && -d "${PREFIX}" ]]; then
    LOG_DIR="${PREFIX}/var/log/cyberdeck"
else
    LOG_DIR="${HOME}/.local/share/cyberdeck/logs"
fi
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE

# ---------------------------------------------------------------------------
# Estado de execução para trap ERR
# ---------------------------------------------------------------------------
CURRENT_STEP="inicialização"
STEP_NUMBER=0
TOTAL_STEPS=8

# ---------------------------------------------------------------------------
# Funções Utilitárias
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

step_begin() {
    STEP_NUMBER=$((STEP_NUMBER + 1))
    CURRENT_STEP="$1"
    info "[${STEP_NUMBER}/${TOTAL_STEPS}] ${CURRENT_STEP}"
}

die() {
    error "$*"
    error "Falha na etapa: ${CURRENT_STEP} (${STEP_NUMBER}/${TOTAL_STEPS})"
    error "Log completo em: ${LOG_FILE}"
    exit 1
}

# Trap ERR sem mascarar status de saída
trap 'die "Erro não tratado (código $?) na etapa: ${CURRENT_STEP}"' ERR

release_lock() {
    local exit_code=$?
    if [[ -n "${LOCK_FD}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi
    exit "${exit_code}"
}
trap release_lock EXIT

acquire_lock() {
    mkdir -p "$(dirname "${LOCK_FILE}")"
    exec {LOCK_FD}>"${LOCK_FILE}" || die "Falha ao abrir lock: ${LOCK_FILE}"
    flock -n "${LOCK_FD}" || die "Outra instalação está em execução (lock: ${LOCK_FILE}). Aguarde ou recupere a sessão interrompida."
    info "Lock de instalação adquirido: ${LOCK_FILE}"
}

# Valida se um comando existe
require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Comando obrigatório não encontrado: ${cmd}"
    fi
}

# Normaliza uma URL de repositório para comparação: remove barra final e o
# sufixo opcional ".git" (o git clone armazena a URL exatamente como digitada,
# e o README usa a forma canônica com ".git").
normalize_repo_url() {
    local url="$1"
    url="${url%/}"
    url="${url%.git}"
    printf '%s' "${url}"
}

# Verifica espaço em disco ANTES de qualquer instalação de pacotes
check_disk_space() {
    local required_mib="${DESKTOP_SPACE_MIB[${AMBIENTE_PARAM}]:-3500}"
    local prefix_path="${PREFIX:-}"

    if [[ -z "${prefix_path}" || ! -d "${prefix_path}" ]]; then
        info "Verificação de espaço ignorada (ambiente não-Termux)."
        return 0
    fi

    local available_kib
    available_kib="$(df -k "${prefix_path}" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "${available_kib}" ]]; then
        warn "Não foi possível ler o espaço disponível em ${prefix_path}; seguindo."
        return 0
    fi

    local available_mib=$((available_kib / 1024))
    info "Espaço disponível: ${available_mib} MiB; necessário: ${required_mib} MiB em ${prefix_path}"
    if (( available_mib < required_mib )); then
        die "Espaço insuficiente em ${prefix_path}: necessário ${required_mib} MiB, disponível ${available_mib} MiB. Libere espaço e execute novamente."
    fi
}

# Valida URL canônica (deve ser a padrão ou override explícito via env)
validate_repo_url() {
    local url="$1"
    if [[ "${url}" != "${CYBERDECK_REPO_URL_DEFAULT}" ]]; then
        warn "URL do repositório não é a canônica: ${url}"
        warn "Canônica: ${CYBERDECK_REPO_URL_DEFAULT}"
        warn "Continuando com override explícito via CYBERDECK_REPO_URL..."
    fi
}

# Canonicaliza e valida parâmetro --desktop
canonicalize_desktop() {
    local input="$1"
    local lower
    lower="$(echo "${input}" | tr '[:upper:]' '[:lower:]')"
    for valid in "${VALID_DESKTOPS[@]}"; do
        if [[ "${lower}" == "${valid}" ]]; then
            echo "${lower}"
            return 0
        fi
    done
    return 1
}

# Calcula SHA-256 de um arquivo
sha256_of() {
    local file="$1"
    sha256sum "${file}" | awk '{print $1}'
}

# Valida integridade do script interno via SHA-256
validate_internal_script() {
    local script_path="$1"
    local expected="${CYBERDECK_SCRIPT_SHA256}"

    local actual
    actual="$(sha256_of "${script_path}")"
    if [[ "${actual}" != "${expected}" ]]; then
        die "Falha na validação SHA-256 do script interno.
  Esperado: ${expected}
  Atual:    ${actual}
  Arquivo:  ${script_path}
  O script pode ter sido corrompido ou alterado. Abortando."
    fi
    info "Validação SHA-256 OK: ${actual}"
}

# ---------------------------------------------------------------------------
# Passos Principais
# ---------------------------------------------------------------------------
step_check_disk_space() {
    step_begin "Verificação de espaço em disco"

    check_disk_space
}

step_bootstrap_host() {
    step_begin "Bootstrap do host Termux (atualização e git)"

    info "Atualizando índices de pacotes (pkg update)..."
    pkg update -y || die "Falha ao executar 'pkg update'. Verifique conectividade e repositórios Termux."

    info "Instalando/atualizando git..."
    pkg install -y git || die "Falha ao instalar 'git'. Verifique se o pacote está disponível no repositório Termux."

    require_cmd git
    info "Git disponível: $(git --version)"
}

step_clone_or_update_repo() {
    step_begin "Clone ou atualização segura do repositório"

    validate_repo_url "${CYBERDECK_REPO_URL}"

    local repo_dir="${CYBERDECK_REPO_DIR}"

    if [[ -d "${repo_dir}/.git" ]]; then
        info "Repositório existente detectado em: ${repo_dir}"
        info "Validando work tree e remote..."

        # Verifica se é work tree válido
        if ! git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            die "Diretório existe mas não é um work tree Git válido: ${repo_dir}"
        fi

        # Valida remote origin
        local remote_url
        remote_url="$(git -C "${repo_dir}" config --get remote.origin.url || true)"
        if [[ -z "${remote_url}" ]]; then
            die "Remote 'origin' não configurado no repositório existente."
        fi

        local expected_url="${CYBERDECK_REPO_URL}"
        if [[ "$(normalize_repo_url "${remote_url}")" != "$(normalize_repo_url "${expected_url}")" ]]; then
            die "Remote origin (${remote_url}) difere da URL esperada (${expected_url}).
Não reconfigurar remote de repo existente para URL diferente.
Use CYBERDECK_REPO_URL para override explícito se necessário."
        fi

        info "Fazendo fetch explícito..."
        git -C "${repo_dir}" fetch origin || die "Falha no 'git fetch origin'."

        # Verifica se há alterações locais não commitadas (dirty work tree)
        if ! git -C "${repo_dir}" diff --quiet || ! git -C "${repo_dir}" diff --cached --quiet; then
            die "Work tree tem alterações locais não commitadas (dirty).
Atualização abortada para não executar conteúdo inconsistente.
Faça commit/stash das alterações antes de prosseguir."
        fi

        info "Fazendo merge/ff-only da branch padrão (origin/HEAD)..."
        local default_branch
        default_branch="$(git -C "${repo_dir}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
        if [[ -z "${default_branch}" ]]; then
            # Fallback: tentar obter branch padrão via remote show
            default_branch="$(git -C "${repo_dir}" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
        fi
        if [[ -z "${default_branch}" ]]; then
            die "Não foi possível determinar a branch padrão do remote origin."
        fi

        # ---- Unidade de release -------------------------------------------------
        # O script interno e o wrapper precisam vir do mesmo release. Se o
        # upstream trouxer um script interno com digest diferente do fixado
        # neste wrapper, abortamos ANTES do merge (o checkout NÃO é alterado)
        # e orientamos a atualizar o wrapper para a nova versão.
        local incoming_hash
        incoming_hash="$(git -C "${repo_dir}" show "origin/${default_branch}:${INTERNAL_SCRIPT_NAME}" 2>/dev/null | sha256sum | awk '{print $1}')"
        if [[ "${incoming_hash}" != "${CYBERDECK_SCRIPT_SHA256}" ]]; then
            die "O upstream trouxe uma nova versão de ${INTERNAL_SCRIPT_NAME}
  Digest fixado neste wrapper: ${CYBERDECK_SCRIPT_SHA256}
  Digest no upstream (origin/${default_branch}): ${incoming_hash}
A atualização foi abortada e o checkout NÃO foi alterado.
Atualize o wrapper para a nova release e execute-o novamente:
  git -C \"${repo_dir}\" fetch origin
  git -C \"${repo_dir}\" merge --ff-only origin/${default_branch}
  bash \"${repo_dir}/${SCRIPT_NAME}\" --desktop=<desktop>"
        fi

        git -C "${repo_dir}" merge --ff-only "origin/${default_branch}" || die "Falha ao atualizar repositório (merge --ff-only). Verifique conflitos ou estado do work tree."
    else
        info "Clonando repositório de ${CYBERDECK_REPO_URL} para ${repo_dir}..."
        git clone "${CYBERDECK_REPO_URL}" "${repo_dir}" || die "Falha no 'git clone'. Verifique URL e conectividade."

        # Validação pós-clone
        if ! git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            die "Clone concluído mas work tree inválido: ${repo_dir}"
        fi
    fi

    # Caminho absoluto do script interno validado
    INTERNAL_SCRIPT_PATH="${repo_dir}/${INTERNAL_SCRIPT_NAME}"
    readonly INTERNAL_SCRIPT_PATH

    if [[ ! -f "${INTERNAL_SCRIPT_PATH}" ]]; then
        die "Script interno não encontrado após clone/update: ${INTERNAL_SCRIPT_PATH}"
    fi
    info "Script interno localizado: ${INTERNAL_SCRIPT_PATH}"
}

step_validate_internal_script() {
    step_begin "Validação de integridade do script interno (SHA-256)"

    validate_internal_script "${INTERNAL_SCRIPT_PATH}"

    info "Concedendo permissão de execução ao script interno..."
    chmod +x "${INTERNAL_SCRIPT_PATH}" || die "Falha ao fazer chmod +x no script interno."
}

step_parse_desktop_arg() {
    step_begin "Processamento e validação do parâmetro --desktop"

    local desktop_param="${1:-}"

    if [[ -z "${desktop_param}" ]]; then
        AMBIENTE_PARAM="${DEFAULT_DESKTOP}"
        info "Nenhum --desktop fornecido. Usando padrão: ${AMBIENTE_PARAM}"
    else
        if canonicalized="$(canonicalize_desktop "${desktop_param}")"; then
            AMBIENTE_PARAM="${canonicalized}"
            info "Desktop canonicalizado: ${AMBIENTE_PARAM}"
        else
            die "Valor inválido para --desktop: '${desktop_param}'.
Valores aceitos: ${VALID_DESKTOPS[*]}
Use --desktop=xfce4 | --desktop=lxqt | --desktop=mate | --desktop=kde"
        fi
    fi
    readonly AMBIENTE_PARAM
}

step_validate_prerequisites() {
    step_begin "Validação de pré-requisitos antes da execução"

    require_cmd bash
    require_cmd sha256sum
    require_cmd git
    # pkg só é obrigatório se estivermos no Termux; --help deve funcionar fora do Termux
    if [[ -n "${PREFIX:-}" ]]; then
        require_cmd pkg
    fi

    # Valida script interno existe e é executável
    if [[ ! -x "${INTERNAL_SCRIPT_PATH}" ]]; then
        die "Script interno não é executável: ${INTERNAL_SCRIPT_PATH}"
    fi

    info "Todos os pré-requisitos validados com sucesso."
}

step_invoke_internal_script() {
    step_begin "Invocação NÃO INTERATIVA do script interno"

    info "Executando: ${INTERNAL_SCRIPT_PATH} --desktop=\"${AMBIENTE_PARAM}\" --lock-held"
    info "Log da execução interna será anexado a: ${LOG_FILE}"

    # Executa em modo não interativo, propagando erro
    if "${INTERNAL_SCRIPT_PATH}" --desktop="${AMBIENTE_PARAM}" --lock-held 2>&1 | tee -a "${LOG_FILE}"; then
        INTERNAL_EXIT_CODE=0
    else
        INTERNAL_EXIT_CODE=${PIPESTATUS[0]}
    fi

    if [[ ${INTERNAL_EXIT_CODE} -ne 0 ]]; then
        die "Script interno falhou com código de saída ${INTERNAL_EXIT_CODE}."
    fi

    info "Script interno concluído com sucesso (exit code 0)."
}

step_finalize() {
    step_begin "Finalização"

    info "======================================================"
    info "Instalação do Cyberdeck concluída com sucesso!"
    info "Desktop selecionado: ${AMBIENTE_PARAM}"
    info "Log completo salvo em: ${LOG_FILE}"
    info "======================================================"
}

# ---------------------------------------------------------------------------
# Função Principal
# ---------------------------------------------------------------------------
main() {
    local desktop_arg=""
    local desktop_provided=false

    # Parse: aceita --desktop=VALOR, --desktop VALOR (posicional), e valor posicional simples
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --desktop=*)
                if [[ "${desktop_provided}" == "true" ]]; then
                    die "Parâmetro --desktop duplicado. Forneça apenas uma vez."
                fi
                desktop_arg="${1#--desktop=}"
                desktop_provided=true
                shift
                ;;
            --desktop)
                if [[ "${desktop_provided}" == "true" ]]; then
                    die "Parâmetro --desktop duplicado. Forneça apenas uma vez."
                fi
                if [[ $# -lt 2 ]]; then
                    die "Formato --desktop requer um valor. Use --desktop=VALOR ou --desktop VALOR"
                fi
                desktop_arg="${2}"
                desktop_provided=true
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Uso: ${SCRIPT_NAME} [--desktop=AMBIENTE] [AMBIENTE]

Opções:
  --desktop=AMBIENTE   Define o ambiente gráfico (xfce4 | lxqt | mate | kde)
  AMBIENTE             Formato posicional legado (ex: xfce4)
                       Padrão: xfce4

Variáveis de ambiente:
  CYBERDECK_REPO_URL   Override da URL do repositório (padrão: ${CYBERDECK_REPO_URL_DEFAULT})
  CYBERDECK_REPO_DIR   Override do diretório de destino (padrão: ${CYBERDECK_REPO_DIR_DEFAULT})

Exemplos:
  ${SCRIPT_NAME} --desktop=xfce4
  ${SCRIPT_NAME} --desktop kde
  ${SCRIPT_NAME} xfce4
  CYBERDECK_REPO_URL=https://github.com/meu/fork ${SCRIPT_NAME} --desktop=mate
EOF
                exit 0
                ;;
            -*)
                die "Argumento desconhecido: ${1}. Use --help para ajuda."
                ;;
            *)
                # Valor posicional (formato legado do README)
                if [[ "${desktop_provided}" == "true" ]]; then
                    die "Desktop já especificado via --desktop. Não forneça valor posicional duplicado."
                fi
                desktop_arg="${1}"
                desktop_provided=true
                shift
                ;;
        esac
    done

    info "=== Iniciando ${SCRIPT_NAME} ==="
    info "Log: ${LOG_FILE}"
    info "Diretório do script: ${SCRIPT_DIR}"
    info "Repositório: ${CYBERDECK_REPO_URL}"
    info "Diretório de destino: ${CYBERDECK_REPO_DIR}"

    step_parse_desktop_arg "${desktop_arg}"
    acquire_lock
    step_check_disk_space
    step_bootstrap_host
    step_clone_or_update_repo
    step_validate_internal_script
    step_validate_prerequisites
    step_invoke_internal_script
    step_finalize
}

# ---------------------------------------------------------------------------
# Guard para testabilidade (source vs execução direta)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi