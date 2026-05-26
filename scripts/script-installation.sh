#!/usr/bin/env bash
# ==============================================================================
# PROJETO: Cyberdeck Termux Android - Installation Wrapper
# ==============================================================================
# DESCRIÇÃO: Script preparatório baseado em 'dialog' para clonar o repositório
# e repassar a execução para o script-termux.sh (que fará a orquestração da DE).
# ==============================================================================

# --- VARIÁVEIS GLOBAIS ---
readonly REPO_URL="https://github.com/giovn-aguiar/linux-android.git"
readonly REPO_DIR="linux-android"
readonly SCRIPT_TERMUX="script-termux.sh"

# --- TRATAMENTO DE SINAIS ---
trap 'clear; echo "[!] Operação cancelada."; exit 1' SIGINT SIGTERM SIGHUP

# --- FUNÇÕES ---
install_dependencies() {
    # Garante que as ferramentas mínimas para a TUI existam antes de iniciar
    if ! command -v dialog >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        echo "[*] Instalando dependências base (dialog, git)..."
        pkg update -y -q > /dev/null 2>&1
        pkg install git dialog -y -q > /dev/null 2>&1
    fi
}

request_storage() {
    dialog --title " Permissão Necessária " --yesno "O Cyberdeck precisa de acesso ao armazenamento interno.\n\nDeseja conceder a permissão agora?" 8 50
    if [[ $? -eq 0 ]]; then
        termux-setup-storage
        dialog --title " Aguarde " --infobox "Aguardando o Android processar a permissão..." 5 50
        sleep 3
    else
        dialog --title " Aviso " --msgbox "Acesso ao armazenamento negado. A instalação pode falhar caso exija arquivos locais." 7 50
    fi
}

clone_repository() {
    dialog --title " Sincronização " --infobox "Clonando/Atualizando repositório do Cyberdeck...\nIsso pode levar alguns segundos." 6 50
    
    if [[ -d "${REPO_DIR}" ]]; then
        cd "${REPO_DIR}" || exit 1
        git pull -q
    else
        git clone -q "${REPO_URL}"
        cd "${REPO_DIR}" || exit 1
    fi
}

execute_installer() {
    if [[ -f "${SCRIPT_TERMUX}" ]]; then
        chmod +x "${SCRIPT_TERMUX}"
        dialog --title " Transição " --msgbox "O ambiente base foi preparado com sucesso.\n\nVocê será redirecionado ao instalador principal para selecionar a interface gráfica (DE)." 9 50
        clear
        ./"${SCRIPT_TERMUX}"
    else
        dialog --title " Erro " --msgbox "O arquivo '${SCRIPT_TERMUX}' não foi encontrado no repositório." 6 50
        exit 1
    fi
}

main() {
    # 1. Dependências silenciosas para a interface
    install_dependencies
    
    # 2. Tela de boas-vindas
    dialog --title " Cyberdeck Termux " --msgbox "Bem-vindo ao instalador inicial do Cyberdeck.\n\nEste script irá preparar o ambiente Termux, atualizar os repositórios e sincronizar os arquivos do projeto." 10 60
    
    # 3. Permissão de Storage
    request_storage
    
    # 4. Clone/Pull
    clone_repository
    
    # 5. Repasse de execução (O script-termux.sh fará o questionamento da DE)
    execute_installer
}

main "$@"
