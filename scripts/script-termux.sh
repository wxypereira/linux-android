#!/usr/bin/env bash
# ==============================================================================
# PROJETO: Cyberdeck Termux Android - Core Installer & DE Orchestrator
# ==============================================================================

set -eo pipefail

# --- GLOBAIS E CONFIGURAÇÕES DE AMBIENTE ---
export DEBIAN_FRONTEND=noninteractive
readonly LOG_FILE="${HOME}/cyberdeck_core_install.log"
readonly BIN_DIR="/data/data/com.termux/files/usr/bin"

DE_NAME="XFCE4"
DE_PACKAGES=""
START_CMD=""

# --- TRATAMENTO DE ESTADO E SINAIS ---
trap 'cleanup_and_abort' SIGINT SIGTERM SIGHUP

cleanup_and_abort() {
    clear
    echo -e "\n[!] Signal de interrupção recebido. Destruindo subshells e abortando."
    pkill -P $$ 2>/dev/null || true
    exit 1
}

# --- FUNÇÕES DE LÓGICA E SETUP ---
config_desktop_environment() {
    local choice
    choice=$(dialog --clear --title " Seleção de Interface Gráfica (DE) " \
        --menu "Mapeamento de arquitetura visual para o Cyberdeck:" 16 65 4 \
        1 "XFCE4 (Recomendado | Melhor densidade/performance)" \
        2 "LXQt  (Low-end | Foco em dispositivos antigos)" \
        3 "MATE  (Mid-end | Estabilidade clássica)" \
        4 "KDE   (High-end | Compositor pesado)" \
        3>&1 1>&2 2>&3)

    if [[ -z "$choice" ]]; then
        clear
        echo "[!] Seleção abortada pelo usuário."
        exit 1
    fi

    case "$choice" in
        1) 
            DE_NAME="XFCE4"
            DE_PACKAGES="xfce4 xfce4-terminal xfce4-whiskermenu-plugin plank-reloaded thunar mousepad"
            START_CMD="exec startxfce4"
            ;;
        2) 
            DE_NAME="LXQt"
            DE_PACKAGES="lxqt qterminal pcmanfm-qt featherpad"
            START_CMD="exec startlxqt"
            ;;
        3) 
            DE_NAME="MATE"
            DE_PACKAGES="mate mate-tweak plank-reloaded mate-terminal"
            START_CMD="exec mate-session"
            ;;
        4) 
            DE_NAME="KDE Plasma"
            DE_PACKAGES="plasma-desktop konsole dolphin"
            START_CMD="exec startplasma-x11"
            ;;
    esac
}

generate_system_scripts() {
    # Inicializador do X11 e PulseAudio
    cat > "${HOME}/start-linux.sh" <<-EOF
#!${BIN_DIR}/bash
pkill -9 -f "termux.x11" 2>/dev/null
pulseaudio --kill 2>/dev/null
sleep 1
pulseaudio --start --exit-idle-time=-1
export PULSE_SERVER=127.0.0.1
termux-x11 :0 -ac &
sleep 2
export DISPLAY=:0
${START_CMD}
EOF
    chmod +x "${HOME}/start-linux.sh"

    # Script de finalização graceful
    cat > "${HOME}/stop-linux.sh" <<-EOF
#!${BIN_DIR}/bash
pkill -9 -f "termux.x11" 2>/dev/null
pkill -9 pulseaudio 2>/dev/null
echo "[+] Sessão X11 e Áudio finalizados."
EOF
    chmod +x "${HOME}/stop-linux.sh"

    # Estrutura base de atalhos XDG
    mkdir -p "${HOME}/Desktop"
    cat > "${HOME}/Desktop/Firefox.desktop" <<-EOF
[Desktop Entry]
Name=Firefox
Exec=firefox
Type=Application
EOF
    chmod +x "${HOME}/Desktop/"*.desktop 2>/dev/null || true
}

execute_pipeline() {
    # Definição imperativa da pipeline (Lógica DRY via array mapping)
    local steps=(
        "Atualizando arvore do apt|apt-get update -y -q && apt-get upgrade -y -q"
        "Injetando repositórios (x11/tur)|apt-get install -y -q x11-repo tur-repo"
        "Compilando servidor gráfico|apt-get install -y -q termux-x11-nightly xorg-xrandr"
        "Instalando DE: ${DE_NAME}|apt-get install -y -q ${DE_PACKAGES}"
        "Forjando drivers GPU (Zink/Vulkan)|apt-get install -y -q mesa-zink vulkan-loader-android"
        "Sincronizando áudio (PulseAudio)|apt-get install -y -q pulseaudio"
        "Provisionando utilitários|apt-get install -y -q firefox vlc git wget curl"
        "Compilando stack Python|apt-get install -y -q python && pip install flask"
        "Estabelecendo runtime x86 (Wine)|apt-get remove -y wine-stable && apt-get install -y -q hangover-wine hangover-wowbox64"
        "Gerando scripts de injeção|generate_system_scripts"
    )

    local total_steps=${#steps[@]}
    local current_step=0

    # Injeção FD limpa para o dialog --gauge
    (
        echo "--- [INIT] Pipeline $DE_NAME ---" > "$LOG_FILE"
        
        for step in "${steps[@]}"; do
            local desc="${step%%|*}"
            local cmd="${step#*|}"
            
            ((current_step++))
            local pct=$(( (current_step * 100) / total_steps ))
            
            # Protocolo stdout exigido pelo dialog --gauge
            echo "XXX"
            echo "$pct"
            echo "$desc"
            echo "XXX"

            echo "-> Executando: $cmd" >> "$LOG_FILE"
            if ! eval "$cmd" >> "$LOG_FILE" 2>&1; then
                # Falha silenciada no pipe, mas força saída com erro
                echo "[!] FATAL: Falha no stage: $desc" >> "$LOG_FILE"
                exit 1
            fi
        done
    ) | dialog --title " Compilação do Sistema " --gauge "\nInicializando subsistema PRoot/Termux..." 10 70

    local exit_status=${PIPESTATUS[0]}
    
    if [[ $exit_status -eq 0 ]]; then
        dialog --title " Sucesso " --msgbox "Ecossistema ${DE_NAME} compilado com sucesso.\n\nExecute ./start-linux.sh para iniciar o servidor gráfico." 8 50
    else
        dialog --title " Kernel Panic " --msgbox "Falha crítica durante a execução da pipeline.\nVerifique o log absoluto em:\n${LOG_FILE}" 9 60
        exit 1
    fi
}

main() {
    clear
    config_desktop_environment
    execute_pipeline
    clear
}

main "$@"
