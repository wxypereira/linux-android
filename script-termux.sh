#!/usr/bin/env bash
# =============================================================================
# CyberDeck Installer — Debian Bookworm ARM64 via proot-distro on Termux
# Non-interactive: --desktop=xfce4|lxqt|mate|kde
# =============================================================================

set -Eeuo pipefail

# ------------------------------ Constants ------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly PROOT_DISTRO_NAME="cyberdeck"
# Debian Bookworm ARM64 pinned image (sha256 digest) — ARM64 ONLY
readonly PROOT_IMAGE="debian:bookworm-slim@sha256:ec8534cda2cb30f29f44f23e135297af7a1496f2990fd8e4e84aa36b081a757a"
# Lock file: safe path when PREFIX absent (fallback to HOME)
readonly LOCK_FILE="${PREFIX:-${HOME}/.termux}/var/lock/cyberdeck-install.lock"
readonly LOG_DIR="${HOME}/.cyberdeck/logs"
# Launchers per ticket/README compatibility
readonly START_SCRIPT="${HOME}/start-linux.sh"
readonly STOP_SCRIPT="${HOME}/stop-linux.sh"
readonly GPU_CONFIG_FILE="${HOME}/.cyberdeck/gpu.conf"

# Disk space margins (MiB) per desktop — base + margin (coherent values)
declare -A DESKTOP_SPACE_MIB=(
    [xfce4]=3500
    [lxqt]=3000
    [mate]=4000
    [kde]=6000
)

# Desktop matrix: single coherent source of truth
# xfce4 MUST use xfce4-session; remove non-existent packages/commands
# Guest base packages: dbus-x11 x11-utils libpulse0 (common to all)
# Guest apps: epiphany-browser (Debian PRoot compatible, not firefox-esr snap) + vlc + git + wget + curl
declare -A DESKTOP_NAME=(
    [xfce4]="XFCE4"
    [lxqt]="LXQt"
    [mate]="MATE"
    [kde]="KDE Plasma"
)
DESKTOP_PKGS_BASE="dbus-x11 x11-utils libpulse0"
declare -A DESKTOP_PKGS=(
    [xfce4]="xfce4 xfce4-terminal thunar mousepad xfce4-session"
    [lxqt]="lxqt lxqt-session qterminal pcmanfm-qt featherpad"
    # mate-session/startplasma-x11 são EXECUTÁVEIS, não pacotes Debian:
    # o pacote que fornece mate-session é mate-session-manager e o que
    # fornece startplasma-x11 é plasma-workspace.
    [mate]="mate-desktop-environment-core mate-terminal mate-session-manager"
    [kde]="plasma-desktop plasma-workspace konsole dolphin"
)
declare -A DESKTOP_EXEC=(
    [xfce4]="xfce4-session"
    [lxqt]="startlxqt"
    [mate]="mate-session"
    [kde]="startplasma-x11"
)
# Guest applications (no firefox-esr snap, no Flask)
GUEST_APPS_PKGS="epiphany-browser vlc git wget curl"

# GPU detection matrix: property_value -> packages|primary_driver|fallback_driver
# Format: packages (to install)|primary_driver (MESA_LOADER_DRIVER_OVERRIDE)|fallback_driver
# Adreno/Qualcomm => mesa-vulkan-drivers|freedreno|llvmpipe
# Mali/Panfrost => mesa-vulkan-drivers|panfrost|llvmpipe
# Generic => libzink mesa-vulkan-drivers|zink|llvmpipe
# Only the packages field is installed; driver names are NOT packages.
# Persisted to GPU_CONFIG_FILE; export MESA_LOADER_DRIVER_OVERRIDE in launcher.
declare -A GPU_DRIVER_MAP=(
    # Adreno/Qualcomm
    ["adreno"]="mesa-vulkan-drivers|freedreno|llvmpipe"
    ["qualcomm"]="mesa-vulkan-drivers|freedreno|llvmpipe"
    ["qcom"]="mesa-vulkan-drivers|freedreno|llvmpipe"
    # Mali/Panfrost
    ["mali"]="mesa-vulkan-drivers|panfrost|llvmpipe"
    ["midgard"]="mesa-vulkan-drivers|panfrost|llvmpipe"
    ["bifrost"]="mesa-vulkan-drivers|panfrost|llvmpipe"
    ["valhall"]="mesa-vulkan-drivers|panfrost|llvmpipe"
    # Videocore (Raspberry Pi)
    ["v3d"]="mesa-vulkan-drivers|v3d|llvmpipe"
    ["vc4"]="mesa-vulkan-drivers|vc4|llvmpipe"
    # Intel
    ["intel"]="mesa-vulkan-drivers|i965|llvmpipe"
    # AMD
    ["amd"]="mesa-vulkan-drivers|radeon|llvmpipe"
    # Generic fallback: zink + llvmpipe
    ["generic"]="mesa-vulkan-drivers|zink|llvmpipe"
)

# ------------------------------ State ----------------------------------------
CURRENT_STEP=0
TOTAL_STEPS=0
DESKTOP_CHOICE=""
LOCK_HELD=false
GPU_KEY=""
GPU_DRIVER_SELECTED=""
GPU_FALLBACK=""
INSTALL_LOG=""

# ------------------------------ Helpers --------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" | tee -a "${INSTALL_LOG}"
}

info()  { log "INFO" "$@"; }
warn()  { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
die()   { error "$@"; exit 1; }

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    info "[$CURRENT_STEP/$TOTAL_STEPS] $*"
}

# Trap handlers: preserve exit code, don't mask failures
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed at step $CURRENT_STEP/$TOTAL_STEPS (exit $exit_code). Log: ${INSTALL_LOG}"
    fi
    # Release lock
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi
    exit "${exit_code}"
}
trap cleanup_on_exit EXIT

cleanup_on_err() {
    local line="$1"; local cmd="$2"; local rc="$3"
    error "Failed at line $line (rc=$rc): $cmd"
}
trap 'cleanup_on_err ${LINENO} "${BASH_COMMAND}" $?' ERR

# ------------------------------ Argument Parsing -----------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --desktop=xfce4|lxqt|mate|kde [--help]

Installs a real Debian Bookworm ARM64 desktop via proot-distro on Termux.

Options:
  --desktop=NAME    Desktop environment (xfce4, lxqt, mate, kde). Required.
  --help            Show this help and exit.

Examples:
  ${SCRIPT_NAME} --desktop=xfce4
  ${SCRIPT_NAME} --desktop=kde
EOF
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        die "Missing required argument: --desktop=xfce4|lxqt|mate|kde"
    fi

    for arg in "$@"; do
        case "${arg}" in
            --desktop=*)
                DESKTOP_CHOICE="${arg#--desktop=}"
                ;;
            --help)
                usage
                exit 0
                ;;
            --lock-held)
                LOCK_HELD=true
                ;;
            *)
                die "Unknown argument: ${arg}. Use --help."
                ;;
        esac
    done

    if [[ -z "${DESKTOP_CHOICE}" ]]; then
        die "Missing required argument: --desktop=xfce4|lxqt|mate|kde"
    fi

    if [[ ! -v DESKTOP_NAME["${DESKTOP_CHOICE}"] ]]; then
        die "Invalid desktop: '${DESKTOP_CHOICE}'. Valid: xfce4, lxqt, mate, kde"
    fi

    info "Desktop selected: ${DESKTOP_NAME[${DESKTOP_CHOICE}]} (${DESKTOP_CHOICE})"
}

# ------------------------------ Pre-flight Checks ----------------------------
check_lock() {
    if [[ "${LOCK_HELD}" == "true" ]]; then
        print_step "Using install lock held by parent installer"
        return 0
    fi
    print_step "Acquiring exclusive install lock"
    mkdir -p "$(dirname "${LOCK_FILE}")"
    # Open lock file descriptor - fail if this fails
    exec {LOCK_FD}>"${LOCK_FILE}" || die "Failed to open lock file: ${LOCK_FILE}"
    # Acquire exclusive non-blocking lock - preserve exit status
    if ! flock -n "${LOCK_FD}"; then
        exec {LOCK_FD}>&- 2>/dev/null || true
        die "Another installation is running (lock: ${LOCK_FILE}). Wait or remove lock file."
    fi
    info "Lock acquired: ${LOCK_FILE}"
}

check_host_deps() {
    print_step "Validating and installing host dependencies"

    # O repositório x11-repo precisa estar habilitado ANTES de instalar os
    # pacotes X11: termux-x11-nightly, xorg-xdpyinfo e xorg-xauth só existem
    # nesse repositório. Sem esta etapa o lote de instalação falha.
    local x11_sources="${PREFIX:-${HOME}/.termux}/etc/apt/sources.list.d/x11.list"
    if [[ ! -f "${x11_sources}" ]]; then
        info "Enabling Termux x11-repo (required for Termux:X11 and X11 utilities)..."
        pkg install -y x11-repo >>"${INSTALL_LOG}" 2>&1 \
            || die "Failed to install x11-repo (Termux X11 repository)"
        pkg update -y >>"${INSTALL_LOG}" 2>&1 \
            || die "pkg update failed after enabling x11-repo"
    fi

    local to_install=()
    command -v proot-distro >/dev/null 2>&1 || to_install+=("proot-distro")
    command -v proot >/dev/null 2>&1 || to_install+=("proot")
    command -v pkg >/dev/null 2>&1 || to_install+=("pkg")
    command -v termux-x11 >/dev/null 2>&1 || to_install+=("termux-x11-nightly")
    command -v pulseaudio >/dev/null 2>&1 || to_install+=("pulseaudio")
    command -v pactl >/dev/null 2>&1 || to_install+=("pulseaudio")
    command -v xdpyinfo >/dev/null 2>&1 || to_install+=("xorg-xdpyinfo")
    command -v xauth >/dev/null 2>&1 || to_install+=("xorg-xauth")

    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing missing host packages: ${to_install[*]}"
        pkg update -y >>"${INSTALL_LOG}" 2>&1 || die "pkg update failed"
        pkg install -y "${to_install[@]}" >>"${INSTALL_LOG}" 2>&1 \
            || die "Failed to install host packages: ${to_install[*]}. Use only official Termux repositories; do NOT use tur-repo."
    fi
    info "Host dependencies satisfied"
}

check_disk_space() {
    print_step "Checking disk space for ${DESKTOP_NAME[${DESKTOP_CHOICE}]}"
    local required_mib="${DESKTOP_SPACE_MIB[${DESKTOP_CHOICE}]}"
    # Safe PREFIX default
    local prefix_path="${PREFIX:-${HOME}/.termux}"
    local available_kib; available_kib="$(df -k "${prefix_path}" | awk 'NR==2 {print $4}')"
    local available_mib=$((available_kib / 1024))

    info "Available: ${available_mib} MiB, Required (with margin): ${required_mib} MiB on ${prefix_path}"
    if (( available_mib < required_mib )); then
        die "Insufficient disk space. Need ${required_mib} MiB, have ${available_mib} MiB on ${prefix_path}. Free space and retry."
    fi
}

detect_gpu() {
    print_step "Detecting GPU hardware"
    local egl_vendor=""; local vulkan_vendor=""; local board_platform=""
    egl_vendor="$(getprop ro.hardware.egl 2>/dev/null || true)"
    vulkan_vendor="$(getprop ro.hardware.vulkan 2>/dev/null || true)"
    board_platform="$(getprop ro.board.platform 2>/dev/null || true)"

    info "ro.hardware.egl=${egl_vendor:-<unset>}"
    info "ro.hardware.vulkan=${vulkan_vendor:-<unset>}"
    info "ro.board.platform=${board_platform:-<unset>}"

    local detected_key="generic"
    for prop in "${egl_vendor}" "${vulkan_vendor}" "${board_platform}"; do
        [[ -z "${prop}" ]] && continue
        local lower_prop="${prop,,}"
        for key in "${!GPU_DRIVER_MAP[@]}"; do
            if [[ "${lower_prop}" == *"${key}"* ]]; then
                detected_key="${key}"
                break 2
            fi
        done
    done

    GPU_KEY="${detected_key}"
    local driver_entry="${GPU_DRIVER_MAP[${detected_key}]}"
    # Parse three fields: packages|primary_driver|fallback_driver
    local gpu_packages="${driver_entry%%|*}"
    local rest="${driver_entry#*|}"
    GPU_DRIVER_SELECTED="${rest%%|*}"
    GPU_FALLBACK="${rest##*|}"

    info "GPU matrix match: key=${detected_key} -> packages=${gpu_packages} driver=${GPU_DRIVER_SELECTED} fallback=${GPU_FALLBACK}"

    # Persist config
    mkdir -p "$(dirname "${GPU_CONFIG_FILE}")"
    cat > "${GPU_CONFIG_FILE}" <<EOF
GPU_KEY=${detected_key}
GPU_PACKAGES=${gpu_packages}
GPU_DRIVER=${GPU_DRIVER_SELECTED}
GPU_FALLBACK=${GPU_FALLBACK}
EGL_VENDOR=${egl_vendor}
VULKAN_VENDOR=${vulkan_vendor}
BOARD_PLATFORM=${board_platform}
EOF
    info "GPU config persisted: ${GPU_CONFIG_FILE}"
}

# ------------------------------ Installation Steps ---------------------------
update_host_pkg() {
    print_step "Updating host package index"
    pkg update -y >>"${INSTALL_LOG}" 2>&1 || die "pkg update failed"
    pkg upgrade -y >>"${INSTALL_LOG}" 2>&1 || die "pkg upgrade failed"
}

install_host_x11_audio() {
    print_step "Installing host X11 and audio (Termux packages only)"
    # Official packages: x11-repo provides termux-x11-nightly and X11 utilities; pulseaudio is from Termux main.
    pkg install -y x11-repo termux-x11-nightly pulseaudio xorg-xdpyinfo xorg-xauth >>"${INSTALL_LOG}" 2>&1 \
        || die "Failed to install host X11/audio packages"
}

install_proot_distro() {
    print_step "Installing proot-distro Debian Bookworm ARM64 (pinned image)"
    # Reuse if already exists
    if proot-distro list --quiet 2>/dev/null | grep -Fxq "${PROOT_DISTRO_NAME}"; then
        info "proot-distro '${PROOT_DISTRO_NAME}' already exists, reusing"
        # Validate login works
        proot-distro login "${PROOT_DISTRO_NAME}" -- /bin/true >>"${INSTALL_LOG}" 2>&1 \
            || die "Existing proot-distro '${PROOT_DISTRO_NAME}' failed validation (login/filesystem)"
    else
        proot-distro install "${PROOT_IMAGE}" --name "${PROOT_DISTRO_NAME}" >>"${INSTALL_LOG}" 2>&1 \
            || die "proot-distro install failed for ${PROOT_IMAGE}"
        # Validate installation
        proot-distro list --quiet 2>/dev/null | grep -Fxq "${PROOT_DISTRO_NAME}" \
            || die "proot-distro list does not show ${PROOT_DISTRO_NAME}"
        info "proot-distro '${PROOT_DISTRO_NAME}' installed and listed"
    fi
}

guest_run() {
    # Run command inside the proot distro
    proot-distro login "${PROOT_DISTRO_NAME}" -- /bin/bash -c "$*" >>"${INSTALL_LOG}" 2>&1
}

guest_apt_update() {
    print_step "Updating guest package index"
    guest_run "apt-get update -y" || die "Guest apt update failed"
}

guest_install_desktop() {
    print_step "Installing guest desktop: ${DESKTOP_NAME[${DESKTOP_CHOICE}]}"
    local gpu_entry="${GPU_DRIVER_MAP[${GPU_KEY:-generic}]}"
    local gpu_packages="${gpu_entry%%|*}"
    local pkgs="${DESKTOP_PKGS_BASE} ${DESKTOP_PKGS[${DESKTOP_CHOICE}]} ${gpu_packages} vulkan-tools"
    guest_run "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs}" \
        || die "Guest desktop package installation failed"
}

guest_install_apps() {
    print_step "Installing guest applications (epiphany-browser, VLC, git, wget, curl)"
    guest_run "DEBIAN_FRONTEND=noninteractive apt-get install -y ${GUEST_APPS_PKGS}" \
        || die "Guest applications installation failed"
}

guest_install_wine() {
    print_step "Installing guest Wine ARM64 (no i386, no wine32, no global symlink)"
    # ARM64 only: install wine (wine64), validate binary
    # User wrapper must call: proot-distro login cyberdeck -- wine ...
    guest_run "DEBIAN_FRONTEND=noninteractive apt-get install -y wine libwine fonts-wine" \
        || die "Guest Wine installation failed"
    # Validate wine binary exists in guest
    guest_run "command -v wine >/dev/null && wine --version" \
        || die "Guest wine binary not functional"
    info "Guest Wine (ARM64) installed and validated — call via 'proot-distro login ${PROOT_DISTRO_NAME} -- wine ...'"
}

guest_cleanup() {
    print_step "Cleaning guest apt cache"
    guest_run "apt-get clean && rm -rf /var/lib/apt/lists/*" \
        || warn "Guest cleanup had issues (non-fatal)"
}

# ------------------------------ Start/Stop Script Generation -----------------
generate_start_script() {
    print_step "Generating start script (atomic, with backup)"
    local tmp_start; tmp_start="$(mktemp "${HOME}/.start-linux.XXXXXX")"
    local desktop_exec="${DESKTOP_EXEC[${DESKTOP_CHOICE}]}"
    local gpu_driver="${GPU_DRIVER_SELECTED}"
    local gpu_fallback="${GPU_FALLBACK}"

    # Use quoted heredoc + explicit placeholder for desktop exec to prevent shell expansion corruption
    cat > "${tmp_start}" <<'START_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# CyberDeck start script — generated by installer
# Starts Termux:X11, PulseAudio, and launches desktop in proot-distro with GPU driver fallback

readonly PROOT_DISTRO_NAME="cyberdeck"
readonly PID_FILE="${HOME}/.cyberdeck/start.pid"
readonly SESSION_LOCK_FILE="${HOME}/.cyberdeck/session.lock"
readonly X11_SOCKET="${TMPDIR:-/tmp}/.X11-unix/X0"
readonly DISPLAY_NUM=":0"
readonly XAUTH_FILE="${HOME}/.Xauthority"
readonly GUEST_HOME="/root"
readonly PULSE_COOKIE_FILE="${HOME}/.cyberdeck/pulse/cookie"
readonly PULSE_TCP_HOST="127.0.0.1"
readonly PULSE_TCP_PORT="4713"
readonly PULSE_SERVER="${PULSE_TCP_HOST}:${PULSE_TCP_PORT}"
readonly GPU_DRIVER="__GPU_DRIVER__"
readonly GPU_FALLBACK="__GPU_FALLBACK__"

# Helper functions
info() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [INFO] $*" >&2
}
error() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [ERROR] $*" >&2
}
warn() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [WARN] $*" >&2
}

# ---- Identidade de processo (PID + start time) ------------------------------
# O PID sozinho nao identifica um processo: o kernel pode reutilizar o numero.
# Cada registro guarda "PID starttime" (campo 22 de /proc/<pid>/stat) e o
# cleanup so sinaliza processos cuja identidade ainda confere.
proc_start_time() {
    local pid="$1"
    [[ -r "/proc/${pid}/stat" ]] || return 1
    sed -E 's/^.*\) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $20}'
}

process_is_owned() {
    local pid="$1" expected="$2" current
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${expected}" ]] || return 1
    current="$(proc_start_time "${pid}" 2>/dev/null || true)"
    [[ -n "${current}" && "${current}" == "${expected}" ]]
}

record_process() {
    local pid="$1" start_time
    start_time="$(proc_start_time "${pid}" 2>/dev/null || true)"
    [[ -n "${start_time}" ]] || return 0
    printf '%s %s\n' "${pid}" "${start_time}" >> "${PID_FILE}"
}

# Remove registros de processos que ja terminaram (evita reuso de PID)
unrecord_process() {
    local pid="$1" tmp
    [[ -f "${PID_FILE}" ]] || return 0
    tmp="$(mktemp "${HOME}/.cyberdeck/pid.XXXXXX")"
    grep -v -E "^${pid} " "${PID_FILE}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${PID_FILE}"
}

cleanup() {
    local exit_code=$?
    # Somente o dono da sessao encerra processos: um launcher que falhou em
    # adquirir o lock nao pode tocar nos registros da sessao ativa.
    if [[ "${OWNS_SESSION}" != "true" ]]; then
        exit "${exit_code}"
    fi
    if [[ -f "${PID_FILE}" ]]; then
        local pid start_time
        while read -r pid start_time; do
            [[ -n "${pid}" ]] || continue
            if process_is_owned "${pid}" "${start_time:-}"; then
                kill -TERM "${pid}" 2>/dev/null || true
            fi
        done < "${PID_FILE}"
        # Wait for TERM, then KILL
        sleep 1
        while read -r pid start_time; do
            [[ -n "${pid}" ]] || continue
            if process_is_owned "${pid}" "${start_time:-}"; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done < "${PID_FILE}"
        rm -f "${PID_FILE}"
    fi
    # Do NOT remove X11 socket - it may belong to another session
    exit "${exit_code}"
}
OWNS_SESSION=false
trap cleanup EXIT TERM INT

# ---- Propriedade da sessao -------------------------------------------------
# O lock exclusivo impede que um segundo launcher sobrescreva os registros do
# launcher ativo (PID file) e depois derrube a sessao alheia no cleanup.
mkdir -p "$(dirname "${PID_FILE}")"
exec {SESSION_FD}>"${SESSION_LOCK_FILE}" || { error "Failed to open session lock: ${SESSION_LOCK_FILE}"; exit 1; }
if ! flock -n "${SESSION_FD}"; then
    error "Another CyberDeck session is already active (lock: ${SESSION_LOCK_FILE})."
    error "Run ${HOME}/stop-linux.sh before starting a new session."
    exit 1
fi

: > "${PID_FILE}"
OWNS_SESSION=true

# ---- Export XAUTHORITY BEFORE starting termux-x11 (for xdpyinfo readiness) ----
export XAUTHORITY="${XAUTH_FILE}"
if [[ ! -s "${XAUTH_FILE}" ]]; then
    x11_cookie="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    xauth -f "${XAUTH_FILE}" add :0 MIT-MAGIC-COOKIE-1 "${x11_cookie}" \
        || { error "Failed to create X11 authentication cookie"; exit 1; }
    xauth -f "${XAUTH_FILE}" add localhost:0 MIT-MAGIC-COOKIE-1 "${x11_cookie}" \
        || { error "Failed to create localhost X11 authentication cookie"; exit 1; }
fi

# ---- Start PulseAudio (host) ----
info "Starting PulseAudio..."
# DO NOT kill global PulseAudio; start only if no ready session
if ! pactl info >/dev/null 2>&1; then
    pulseaudio --daemonize=no --exit-idle-time=-1 --log-target=syslog &
    PA_PID=$!
    record_process "${PA_PID}"
    info "PulseAudio PID: ${PA_PID}"

    # Wait for PulseAudio socket with timeout
    pa_ready=0
    for i in {1..20}; do
        if pactl info >/dev/null 2>&1; then
            pa_ready=1; break
        fi
        sleep 0.2
    done
    [[ ${pa_ready} -eq 1 ]] || { error "PulseAudio failed to start"; exit 1; }
else
    info "PulseAudio already running (existing session), reusing"
fi

# ---- Transporte de audio para o guest --------------------------------------
# O PulseAudio do Termux carrega apenas o protocolo unix (o TCP vem
# comentado no default.pa). O guest precisa de um endpoint: carregamos o
# modulo TCP limitado a 127.0.0.1 e protegido por cookie, que o cliente le
# atraves da variavel PULSE_COOKIE.
mkdir -p "$(dirname "${PULSE_COOKIE_FILE}")"
if ! pactl list short modules 2>/dev/null | grep -q 'module-native-protocol-tcp'; then
    info "Loading PulseAudio TCP module (loopback only, cookie auth)..."
    pactl load-module module-native-protocol-tcp \
        "listen=${PULSE_TCP_HOST}" "port=${PULSE_TCP_PORT}" \
        auth-cookie-enabled=yes "auth-cookie=${PULSE_COOKIE_FILE}" >/dev/null 2>&1 \
        || { error "Failed to load PulseAudio TCP module"; exit 1; }
fi
export PULSE_SERVER
export PULSE_COOKIE="${PULSE_COOKIE_FILE}"
if ! PULSE_SERVER="${PULSE_SERVER}" PULSE_COOKIE="${PULSE_COOKIE_FILE}" pactl info >/dev/null 2>&1; then
    error "PulseAudio TCP transport not reachable at ${PULSE_SERVER}"
    exit 1
fi

# ---- Start Termux:X11 (host) ----
info "Starting Termux:X11 on ${DISPLAY_NUM}..."
# No -ac; use proper X authentication
termux-x11 "${DISPLAY_NUM}" -auth "${XAUTH_FILE}" &
X11_PID=$!
record_process "${X11_PID}"
info "Termux:X11 PID: ${X11_PID}"

# Wait for X11 socket + readiness with timeout
x11_ready=0
for i in {1..30}; do
    if [[ -S "${X11_SOCKET}" ]] && xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
        x11_ready=1; break
    fi
    sleep 0.2
done
[[ ${x11_ready} -eq 1 ]] || { error "Termux:X11 failed to become ready"; exit 1; }

export DISPLAY="${DISPLAY_NUM}"

# ---- Launch desktop in proot-distro with GPU driver fallback ----
run_desktop_with_driver() {
    local driver="$1"
    local attempt_pid=""
    local rc=0
    info "Launching desktop (__DESKTOP_EXEC__) in proot-distro with driver=${driver}..."
    proot-distro login --shared-x11 --shared-home "${PROOT_DISTRO_NAME}" -- /bin/bash -c "
        export DISPLAY=${DISPLAY_NUM}
        export XAUTHORITY=${GUEST_HOME}/.Xauthority
        export PULSE_SERVER=${PULSE_SERVER}
        export PULSE_COOKIE=${GUEST_HOME}/.cyberdeck/pulse/cookie
        export XDG_RUNTIME_DIR=/tmp/cyberdeck-runtime-\$(id -u)
        mkdir -p \${XDG_RUNTIME_DIR}
        if [[ -n \"${driver}\" ]]; then
            export MESA_LOADER_DRIVER_OVERRIDE=${driver}
        fi
        dbus-launch --exit-with-session __DESKTOP_EXEC__
    " &
    attempt_pid=$!
    record_process "${attempt_pid}"
    wait "${attempt_pid}" || rc=$?
    # A tentativa terminou: remove o registro para que o cleanup nao sinalize
    # um PID que possa ter sido reutilizado pelo kernel.
    unrecord_process "${attempt_pid}"
    return "${rc}"
}

# Try primary driver first, then fallback once
desktop_exit_code=0
if [[ -n "${GPU_DRIVER}" && "${GPU_DRIVER}" != "libzink" ]]; then
    export MESA_LOADER_DRIVER_OVERRIDE="${GPU_DRIVER}"
    if run_desktop_with_driver "${GPU_DRIVER}"; then
        desktop_exit_code=0
    else
        desktop_exit_code=$?
    fi
    if [[ ${desktop_exit_code} -ne 0 && -n "${GPU_FALLBACK}" ]]; then
        warn "Desktop exited with code ${desktop_exit_code} using driver ${GPU_DRIVER}, trying fallback ${GPU_FALLBACK}..."
        export MESA_LOADER_DRIVER_OVERRIDE="${GPU_FALLBACK}"
        if run_desktop_with_driver "${GPU_FALLBACK}"; then
            desktop_exit_code=0
        else
            desktop_exit_code=$?
        fi
    fi
else
    if run_desktop_with_driver ""; then
        desktop_exit_code=0
    else
        desktop_exit_code=$?
    fi
fi

exit ${desktop_exit_code}
START_EOF

    # Substitute placeholders (quoted heredoc prevents premature expansion)
    sed -i "s|__DESKTOP_EXEC__|${desktop_exec}|g" "${tmp_start}"
    sed -i "s|__GPU_DRIVER__|${gpu_driver}|g" "${tmp_start}"
    sed -i "s|__GPU_FALLBACK__|${gpu_fallback}|g" "${tmp_start}"

    chmod +x "${tmp_start}"

    # Atomic move with versioned backup
    if [[ -f "${START_SCRIPT}" ]]; then
        local backup
        backup="${START_SCRIPT}.$(date '+%Y%m%d-%H%M%S').bak"
        mv "${START_SCRIPT}" "${backup}"
        info "Backed up existing start script to ${backup}"
    fi
    mv "${tmp_start}" "${START_SCRIPT}"
    info "Start script installed: ${START_SCRIPT}"
}

generate_stop_script() {
    print_step "Generating stop script (atomic, with backup)"
    local tmp_stop; tmp_stop="$(mktemp "${HOME}/.stop-linux.XXXXXX")"

    cat > "${tmp_stop}" <<'STOP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# CyberDeck stop script — generated by installer
# Stops desktop, Termux:X11, and PulseAudio for THIS SESSION ONLY

readonly PID_FILE="${HOME}/.cyberdeck/start.pid"

if [[ ! -f "${PID_FILE}" ]]; then
    echo "No PID file found (${PID_FILE}). Nothing to stop for this session."
    exit 0
fi

# ---- Identidade de processo (PID + start time) ------------------------------
# O PID sozinho nao identifica um processo: o kernel pode reutilizar o numero.
proc_start_time() {
    local pid="$1"
    [[ -r "/proc/${pid}/stat" ]] || return 1
    sed -E 's/^.*\) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $20}'
}

process_is_owned() {
    local pid="$1" expected="$2" current
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${expected}" ]] || return 1
    current="$(proc_start_time "${pid}" 2>/dev/null || true)"
    [[ -n "${current}" && "${current}" == "${expected}" ]]
}

if [[ ! -s "${PID_FILE}" ]]; then
    echo "PID file empty. Nothing to stop."
    rm -f "${PID_FILE}"
    exit 0
fi

echo "Stopping processes for this session:"
while read -r pid start_time; do
    [[ -n "${pid}" ]] || continue
    # Validate PID is numeric
    if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
        echo "  Skipping invalid PID: ${pid}"
        continue
    fi
    if process_is_owned "${pid}" "${start_time:-}"; then
        kill -TERM "${pid}" 2>/dev/null && echo "  Sent TERM to ${pid}" || true
    else
        echo "  Skipping ${pid}: identity mismatch (process exited or PID reused)"
    fi
done < "${PID_FILE}"

# Wait for graceful shutdown
sleep 2

while read -r pid start_time; do
    [[ -n "${pid}" ]] || continue
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if process_is_owned "${pid}" "${start_time:-}"; then
        kill -KILL "${pid}" 2>/dev/null && echo "  Sent KILL to ${pid}" || true
    fi
done < "${PID_FILE}"

# Do NOT remove X11 socket - it may belong to another session

rm -f "${PID_FILE}"
echo "Desktop stopped."
STOP_EOF

    chmod +x "${tmp_stop}"

    if [[ -f "${STOP_SCRIPT}" ]]; then
        local backup
        backup="${STOP_SCRIPT}.$(date '+%Y%m%d-%H%M%S').bak"
        mv "${STOP_SCRIPT}" "${backup}"
        info "Backed up existing stop script to ${backup}"
    fi
    mv "${tmp_stop}" "${STOP_SCRIPT}"
    info "Stop script installed: ${STOP_SCRIPT}"
}

# ------------------------------ Wine Wrapper Generation -----------------------
generate_wine_wrapper() {
    print_step "Generating user Wine wrapper (atomic, with versioned backup)"
    local wrapper_path="${HOME}/.local/bin/cyberdeck-wine"
    local tmp_wrapper; tmp_wrapper="$(mktemp "${HOME}/.cyberdeck-wine.XXXXXX")"

    cat > "${tmp_wrapper}" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# CyberDeck Wine wrapper — generated by installer
# Runs wine inside the proot-distro guest with the session's X11 and audio

set -Eeuo pipefail

readonly PROOT_DISTRO_NAME="cyberdeck"
readonly HOST_HOME="${HOME}"
readonly GUEST_HOME="/root"

if [[ $# -lt 1 ]]; then
    echo "Uso: cyberdeck-wine <executavel-windows> [args...]" >&2
    exit 2
fi

target="$1"; shift

login_args=(--shared-x11 --shared-home)
work_dir=""
bind_src=""

# Caminhos relativos do host nao existem no guest: resolvemos o caminho
# absoluto no host e traduzimos para o caminho visivel no guest, ajustando o
# work-dir e fazendo bind dos diretorios fora da home compartilhada.
if [[ "${target}" == */* && "${target}" != [A-Za-z]:* && "${target}" != [A-Za-z]:*\\* ]]; then
    target_dir="$(cd "$(dirname "${target}")" 2>/dev/null && pwd)" || target_dir=""
    if [[ -n "${target_dir}" ]]; then
        abs_target="${target_dir}/$(basename "${target}")"
        if [[ "${abs_target}" == "${HOST_HOME}"/* ]]; then
            target="${GUEST_HOME}${abs_target#"${HOST_HOME}"}"
        else
            target="${abs_target}"
            bind_src="${target_dir}"
        fi
        work_dir="$(dirname "${target}")"
    fi
fi

if [[ -n "${bind_src}" ]]; then
    login_args+=(--bind "${bind_src}:${bind_src}")
fi
if [[ -n "${work_dir}" ]]; then
    login_args+=(--work-dir "${work_dir}")
fi

exec proot-distro login "${login_args[@]}" \
    -e "DISPLAY=${DISPLAY:-:0}" \
    -e "XAUTHORITY=${GUEST_HOME}/.Xauthority" \
    -e "PULSE_SERVER=127.0.0.1:4713" \
    -e "PULSE_COOKIE=${GUEST_HOME}/.cyberdeck/pulse/cookie" \
    "${PROOT_DISTRO_NAME}" -- wine "${target}" "$@"
WRAPPER_EOF

    chmod +x "${tmp_wrapper}"

    # Create directory if needed
    mkdir -p "$(dirname "${wrapper_path}")"

    # Atomic move with versioned backup
    if [[ -f "${wrapper_path}" ]]; then
        local backup
        backup="${wrapper_path}.$(date '+%Y%m%d-%H%M%S').bak"
        mv "${wrapper_path}" "${backup}"
        info "Backed up existing Wine wrapper to ${backup}"
    fi
    mv "${tmp_wrapper}" "${wrapper_path}"
    info "Wine wrapper installed: ${wrapper_path}"
    info "Usage: cyberdeck-wine <windows-executable> [args...]"
}

# ------------------------------ Final Validation -----------------------------
final_validation() {
    print_step "Final validation"
    local errors=0

    # Validate scripts exist and are executable
    [[ -x "${START_SCRIPT}" ]] || { error "Start script not executable: ${START_SCRIPT}"; errors=$((errors+1)); }
    [[ -x "${STOP_SCRIPT}" ]] || { error "Stop script not executable: ${STOP_SCRIPT}"; errors=$((errors+1)); }
    [[ -x "${HOME}/.local/bin/cyberdeck-wine" ]] || { error "Wine wrapper not executable: ${HOME}/.local/bin/cyberdeck-wine"; errors=$((errors+1)); }

    # Validate proot distro exists (tolerant matching for formatted output)
    if ! proot-distro list --quiet 2>/dev/null | grep -Fxq "${PROOT_DISTRO_NAME}"; then
        error "proot-distro ${PROOT_DISTRO_NAME} not listed"
        errors=$((errors+1))
    fi

    # Validate guest desktop exec binary
    if ! guest_run "command -v ${DESKTOP_EXEC[${DESKTOP_CHOICE}]} >/dev/null"; then
        error "Guest desktop executable ${DESKTOP_EXEC[${DESKTOP_CHOICE}]} not found"
        errors=$((errors+1))
    fi

    # Validate guest wine
    if ! guest_run "command -v wine >/dev/null && wine --version"; then
        error "Guest wine not functional"
        errors=$((errors+1))
    fi

    # Validate GPU config
    [[ -f "${GPU_CONFIG_FILE}" ]] || { error "GPU config missing: ${GPU_CONFIG_FILE}"; errors=$((errors+1)); }

    # Validate host termux-x11
    command -v termux-x11 >/dev/null 2>&1 || { error "Host termux-x11 not in PATH"; errors=$((errors+1)); }

    if (( errors > 0 )); then
        die "Final validation failed with ${errors} error(s). See log: ${INSTALL_LOG}"
    fi

    info "All validations passed"
}

# ------------------------------ Main -----------------------------------------
main() {
    mkdir -p "${LOG_DIR}"
    INSTALL_LOG="${LOG_DIR}/install-$(date '+%Y%m%d-%H%M%S').log"
    : > "${INSTALL_LOG}"
    info "=== CyberDeck Installer v${SCRIPT_VERSION} ==="
    info "Log: ${INSTALL_LOG}"

    parse_args "$@"

    # Count steps dynamically to avoid duplication
    # Steps: lock, host-deps, disk-space, gpu, host-pkg-update, host-x11-audio,
    #        proot-distro, guest-apt-update, guest-desktop, guest-apps, guest-wine,
    #        guest-cleanup, start-script, stop-script, wine-wrapper, validation = 16
    TOTAL_STEPS=16

    # Ordem importante: a verificação de espaço acontece ANTES de qualquer
    # mutação de pacotes (pkg update/install), conforme documentado no README.
    check_lock
    check_disk_space
    check_host_deps
    detect_gpu
    update_host_pkg
    install_host_x11_audio
    install_proot_distro
    guest_apt_update
    guest_install_desktop
    guest_install_apps
    guest_install_wine
    guest_cleanup
    generate_start_script
    generate_stop_script
    generate_wine_wrapper
    final_validation

    info "=== INSTALLATION SUCCESSFUL ==="
    info "Desktop: ${DESKTOP_NAME[${DESKTOP_CHOICE}]} (${DESKTOP_CHOICE})"
    info "Start:  ${START_SCRIPT}"
    info "Stop:   ${STOP_SCRIPT}"
    info "Log:    ${INSTALL_LOG}"
    info ""
    info "To start the desktop:"
    info "  1. Open Termux:X11 app"
    info "  2. Run: ${START_SCRIPT}"
    info "To stop:"
    info "  ${STOP_SCRIPT}"
}

# Guard for testing/sourcing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi