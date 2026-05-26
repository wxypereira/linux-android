#!/usr/bin/env bash
# ==============================================================================
# Cyberdeck Termux Android
# ==============================================================================

# --- CONFIGURAÇÕES GLOBAIS ---
readonly APP_NAME="Cyberdeck Termux"
readonly APP_VERSION="1.4.0"
readonly DIR_BASE="$(pwd)"
readonly DIR_SCRIPTS="${DIR_BASE}/scripts"
readonly DIR_LOGS="${DIR_BASE}/logs"

# Gerar log
export FILE_LOG="${DIR_LOGS}/cyberdeck_$(date +%d_%m_%Y).log"
readonly MIN_DISK_MB=2048

# --- INICIALIZAÇÃO ---
mkdir -p "${DIR_SCRIPTS}" "${DIR_LOGS}"
touch "${FILE_LOG}"

# --- TRATAMENTO DE SINAIS ---
trap 'cleanup_and_exit' SIGINT SIGTERM SIGHUP

cleanup_and_exit() {
    clear
    echo -e "\n[!] Operação cancelada. Encerrando o script." | tee -a "${FILE_LOG}"
    exit 1
}

# --- FUNÇÕES DE DETECÇÃO ---
check_environment() {
    if [[ -n "${PREFIX}" && "${PREFIX}" == *"/com.termux/"* ]]; then
        ENV_TYPE="Termux"
    elif [[ -f "/etc/os-release" ]]; then
        ENV_TYPE="Linux"
    else
        ENV_TYPE="Desconhecido"
    fi

    if [[ -f "${HOME}/start-linux.sh" ]]; then
        ENV_STATUS="Instalado"
    else
        ENV_STATUS="Não Instalado"
    fi
}

verify_dependencies() {
    local deps=("dialog" "df" "awk")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            if [[ "$cmd" == "dialog" && "$ENV_TYPE" == "Termux" ]]; then
                echo "[*] Instalando dependência crítica: dialog..."
                pkg update -y -q && pkg install dialog -y -q
            else
                echo "[!] Erro fatal: Dependência '$cmd' não encontrada." | tee -a "${FILE_LOG}"
                exit 1
            fi
        fi
    done
}

check_disk_space() {
    local available_space
    available_space=$(df -m . | awk 'NR==2 {print $4}')
    if [[ "$available_space" -lt "$MIN_DISK_MB" ]]; then
        dialog --title " Erro de Hardware " --msgbox "Espaço insuficiente!\n\nRequerido: ${MIN_DISK_MB}MB\nDisponível: ${available_space}MB" 8 40
        return 1
    fi
    return 0
}

# --- EXECUÇÃO ---
run_script() {
    local script_name="$1"
    local script_path="${DIR_SCRIPTS}/${script_name}"
    
    [[ ! -f "$script_path" ]] && script_path="${DIR_BASE}/${script_name}"

    if [[ ! -f "$script_path" ]]; then
        dialog --title " Erro " --msgbox "Script não localizado na raiz ou em /scripts:\n${script_path}" 8 50
        return 1
    fi

    chmod +x "$script_path"

    # Confirmação de execução
    dialog --title " $script_name " --yesno "Deseja executar o script?" 7 40
    if [[ $? -ne 0 ]]; then
        # Usuário selecionou "Não". Retorna ao menu principal.
        return 0 
    fi

    # Passa o controle da tela para o script filho
    clear
    echo "--- [INIT] Execução de ${script_name} em $(date +%H:%M:%S) ---" >> "${FILE_LOG}"
    
    # O script assume o foreground. Suas TUIs e outputs serão renderizados passo a passo.
    bash "$script_path"
    local exit_code=$?

    echo "--- [END] ${script_name} finalizado (Exit Code: ${exit_code}) ---" >> "${FILE_LOG}"
}

# --- GERENCIAMENTO DE LOGS ---
manage_logs() {
    while true; do
        # Retornar lista de todos os logs gerados
        local log_files=()
        for file in "${DIR_LOGS}"/cyberdeck_*.log; do
            [[ -f "$file" ]] || continue
            log_files+=("$(basename "$file")" "Visualizar Log")
        done

        if [[ ${#log_files[@]} -eq 0 ]]; then
            dialog --title " Status e Logs " --msgbox "Nenhum arquivo de log encontrado no diretório:\n${DIR_LOGS}" 8 50
            return 0
        fi

        local selected_log
        selected_log=$(dialog --stdout --title " Gerenciador de Logs " \
            --cancel-label "Voltar ao Menu" \
            --menu "Selecione o arquivo para inspeção:" \
            15 65 8 "${log_files[@]}")

        # Se apertou Esc ou Cancelar, volta ao menu
        if [[ -z "$selected_log" ]]; then
            break 
        fi

        # Abre o log
        dialog --title " Lendo: $selected_log " --textbox "${DIR_LOGS}/${selected_log}" 22 85
    done
}

# --- CONTROLE DE AMBIENTE ---
start_linux_env() {
    if [[ "$ENV_STATUS" != "Instalado" ]]; then
         dialog --title " Aviso " --msgbox "Ambiente Linux não detectado.\nExecute a instalação (Opções 1 e 2) primeiro." 8 50
         return 1
    fi
    bash "${HOME}/start-linux.sh" > /dev/null 2>&1 &
    dialog --title " Boot " --msgbox "Sinal enviado ao servidor gráfico.\nAbra o app Termux:X11." 7 40
}

stop_linux_env() {
    if [[ -f "${HOME}/stop-linux.sh" ]]; then
        bash "${HOME}/stop-linux.sh" > /dev/null 2>&1
        dialog --title " Shutdown " --msgbox "Processos encerrados com sucesso." 5 40
    else
        pkill -9 -f "termux.x11" 2>/dev/null; pkill -9 pulseaudio 2>/dev/null
        dialog --title " Force Kill " --msgbox "Processos zumbis aniquilados." 5 40
    fi
}

# --- MENU PRINCIPAL ---
show_menu() {
    while true; do
        check_environment
        
        local selection
        selection=$(dialog --stdout --title " ${APP_NAME} " \
            --backtitle "OS: ${ENV_TYPE} | Status: ${ENV_STATUS} | Log: $(basename "$FILE_LOG")" \
            --cancel-label "Sair" \
            --menu "Menu de Principal:" 17 60 7 \
            1 "Configurações iniciais" \
            2 "Baixar Ambiente Linux" \
	    3 "Deploy Completo (1 e 2)" \
            4 "Iniciar Ambiente" \
            5 "Parar Ambiente" \
            6 "Logs" \
            7 "Sair")
        
        [[ $? -ne 0 ]] && break
        
        case $selection in
            1) run_script "script-installation.sh" ;;
            2) check_disk_space && run_script "script-termux.sh" ;;
            3) check_disk_space && { run_script "script-installation.sh"; run_script "script-termux.sh"; } ;;
            4) start_linux_env ;;
            5) stop_linux_env ;;
            6) manage_logs ;;
            7) break ;;
        esac
    done
    clear
    echo "[+] Cyberdeck encerrado."
}

# --- ENTRYPOINT ---
main() {
    check_environment
    verify_dependencies
    show_menu
}

main "$@"
