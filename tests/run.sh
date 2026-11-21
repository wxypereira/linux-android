#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly INSTALLER="${REPO_ROOT}/script-installation.sh"
readonly INTERNAL="${REPO_ROOT}/script-termux.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$((PASSED + FAILED))" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf 'not ok %d - %s\n' "$((PASSED + FAILED))" "$1" >&2
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${message}"
    else
        fail "${message}: esperava '${needle}'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        pass "${message}"
    else
        fail "${message}: não deve conter '${needle}'"
    fi
}

assert_file() {
    if [[ -f "$1" ]]; then
        pass "$2"
    else
        fail "$2: arquivo ausente $1"
    fi
}

# NOTA: uma função chamada como condição (`if "$@"`) desativa `errexit` em
# todo o seu corpo. Por isso cada teste propaga as falhas explicitamente
# (`|| return 1` / `|| exit 1`) e nunca depende do `set -e` implícito.
run_test() {
    local name="$1"
    shift
    if "$@"; then
        pass "${name}"
    else
        fail "${name}"
    fi
}

test_syntax() {
    bash -n "${INSTALLER}" || return 1
    bash -n "${INTERNAL}" || return 1
}

test_installer_desktop_contract() {
    local output
    output="$(
        source "${INSTALLER}" || exit 1
        canonicalize_desktop XFCE4 || exit 1
        canonicalize_desktop lxqt || exit 1
        canonicalize_desktop mate || exit 1
        canonicalize_desktop kde || exit 1
    )" || return 1
    [[ "${output}" == $'xfce4\nlxqt\nmate\nkde' ]] || return 1
}

test_installer_rejects_invalid_desktop() {
    ! (
        source "${INSTALLER}" || exit 1
        canonicalize_desktop invalid
    )
}

test_installer_die_returns_failure() {
    ! (
        source "${INSTALLER}" || exit 1
        die "expected failure"
    )
}

test_installer_normalizes_repo_url() {
    (
        source "${INSTALLER}" || exit 1
        [[ "$(normalize_repo_url 'https://github.com/wxypereira/linux-android.git')" == "https://github.com/wxypereira/linux-android" ]] || exit 1
        [[ "$(normalize_repo_url 'https://github.com/wxypereira/linux-android/')" == "https://github.com/wxypereira/linux-android" ]] || exit 1
        [[ "$(normalize_repo_url 'https://github.com/wxypereira/linux-android')" == "https://github.com/wxypereira/linux-android" ]] || exit 1
        [[ "$(normalize_repo_url 'https://github.com/outro/repo.git')" == "https://github.com/outro/repo" ]] || exit 1
    )
}

test_installer_checks_disk_space_before_bootstrap() {
    # Compara a ORDEM DAS CHAMADAS em main (linhas indentadas), não a ordem
    # das definições das funções.
    local disk_line bootstrap_line
    disk_line="$(grep -n -E '^[[:space:]]+step_check_disk_space$' "${INSTALLER}" | head -1 | cut -d: -f1)" || return 1
    bootstrap_line="$(grep -n -E '^[[:space:]]+step_bootstrap_host$' "${INSTALLER}" | head -1 | cut -d: -f1)" || return 1
    [[ -n "${disk_line}" && -n "${bootstrap_line}" ]] || return 1
    (( disk_line < bootstrap_line )) || return 1
}

test_internal_rejects_invalid_desktop() {
    ! (
        source "${INTERNAL}" || exit 1
        INSTALL_LOG="${TEST_TMP}/invalid-desktop.log"
        : > "${INSTALL_LOG}"
        parse_args --desktop=invalid
    )
}

test_internal_matrix_contract() {
    (
        source "${INTERNAL}" || exit 1
        [[ "${DESKTOP_EXEC[xfce4]}" == "xfce4-session" ]] || exit 1
        [[ "${DESKTOP_EXEC[lxqt]}" == "startlxqt" ]] || exit 1
        [[ "${DESKTOP_EXEC[mate]}" == "mate-session" ]] || exit 1
        [[ "${DESKTOP_EXEC[kde]}" == "startplasma-x11" ]] || exit 1
        [[ "${PROOT_IMAGE}" == *"@sha256:"* ]] || exit 1
        [[ "${PROOT_IMAGE}" == *"bookworm-slim"* ]] || exit 1
        grep -q 'proot-distro list --quiet' "${INTERNAL}" || exit 1
        grep -q -- '--shared-x11' "${INTERNAL}" || exit 1
        grep -q 'termux-x11-nightly' "${INTERNAL}" || exit 1
        grep -q 'xorg-xdpyinfo' "${INTERNAL}" || exit 1
        grep -q 'xorg-xauth' "${INTERNAL}" || exit 1
    )
}

test_internal_desktop_packages_are_real_packages() {
    (
        source "${INTERNAL}" || exit 1
        # startplasma-x11 e mate-session são EXECUTÁVEIS, não pacotes Debian:
        # passá-los ao apt-get aborta a instalação do desktop.
        [[ " ${DESKTOP_PKGS[kde]} " != *" startplasma-x11 "* ]] || exit 1
        [[ " ${DESKTOP_PKGS[mate]} " != *" mate-session "* ]] || exit 1
        [[ " ${DESKTOP_PKGS[kde]} " == *" plasma-workspace "* ]] || exit 1
        [[ " ${DESKTOP_PKGS[mate]} " == *" mate-session-manager "* ]] || exit 1
    )
}

test_internal_enables_x11_repo_before_install() {
    local x11_line install_line
    x11_line="$(grep -n 'pkg install -y x11-repo' "${INTERNAL}" | head -1 | cut -d: -f1)" || return 1
    install_line="$(grep -n 'to_install+=("termux-x11-nightly")' "${INTERNAL}" | head -1 | cut -d: -f1)" || return 1
    [[ -n "${x11_line}" && -n "${install_line}" ]] || return 1
    (( x11_line < install_line )) || return 1
}

test_gpu_matrix_contract() {
    (
        source "${INTERNAL}" || exit 1
        [[ "${GPU_DRIVER_MAP[adreno]}" == "mesa-vulkan-drivers|freedreno|llvmpipe" ]] || exit 1
        [[ "${GPU_DRIVER_MAP[mali]}" == "mesa-vulkan-drivers|panfrost|llvmpipe" ]] || exit 1
        [[ "${GPU_DRIVER_MAP[generic]}" == *"zink"* ]] || exit 1
        [[ "${GPU_DRIVER_MAP[generic]}" == *"llvmpipe"* ]] || exit 1
    )
}

test_gpu_detection_fixtures() {
    local case_name value expected
    for case_name in adreno mali generic; do
        case "${case_name}" in
            adreno) value="adreno"; expected="freedreno" ;;
            mali) value="mali"; expected="panfrost" ;;
            generic) value="generic-gpu"; expected="zink" ;;
        esac

        (
            export HOME="${TEST_TMP}/gpu-${case_name}"
            mkdir -p "${HOME}" || exit 1
            source "${INTERNAL}" || exit 1
            INSTALL_LOG="${HOME}/install.log"
            : > "${INSTALL_LOG}"
            getprop() {
                case "$1" in
                    ro.hardware.egl) printf '%s\n' "${value}" ;;
                    ro.hardware.vulkan) printf '%s\n' "${value}" ;;
                    ro.board.platform) printf '%s\n' "${value}" ;;
                    *) printf '\n' ;;
                esac
            }
            detect_gpu || exit 1
            [[ "${GPU_DRIVER_SELECTED}" == "${expected}" ]] || exit 1
            [[ -f "${GPU_CONFIG_FILE}" ]] || exit 1
            grep -q "GPU_DRIVER=${expected}" "${GPU_CONFIG_FILE}" || exit 1
        ) || return 1
    done
}

test_generated_launchers() {
    local home="${TEST_TMP}/launchers"
    mkdir -p "${home}" || return 1
    (
        export HOME="${home}"
        source "${INTERNAL}" || exit 1
        INSTALL_LOG="${home}/install.log"
        : > "${INSTALL_LOG}"
        DESKTOP_CHOICE="xfce4"
        GPU_KEY="generic"
        GPU_DRIVER_SELECTED="zink"
        GPU_FALLBACK="llvmpipe"
        generate_start_script || exit 1
        generate_stop_script || exit 1
        generate_wine_wrapper || exit 1

        bash -n "${START_SCRIPT}" || exit 1
        bash -n "${STOP_SCRIPT}" || exit 1
        bash -n "${HOME}/.local/bin/cyberdeck-wine" || exit 1

        local start_content stop_content wrapper_content
        start_content="$(cat "${START_SCRIPT}")" || exit 1
        stop_content="$(cat "${STOP_SCRIPT}")" || exit 1
        wrapper_content="$(cat "${HOME}/.local/bin/cyberdeck-wine")" || exit 1

        [[ "${start_content}" != *'pkill'* ]] || exit 1
        [[ "${start_content}" != *'lsof'* ]] || exit 1
        [[ "${start_content}" != *' -ac '* ]] || exit 1
        [[ "${start_content}" == *'xfce4-session'* ]] || exit 1
        [[ "${start_content}" == *'PID_FILE'* ]] || exit 1
        [[ "${start_content}" == *'kill -TERM'* ]] || exit 1
        [[ "${start_content}" == *'kill -KILL'* ]] || exit 1
        [[ "${start_content}" == *'GPU_FALLBACK'* ]] || exit 1

        # Sessão exclusiva: lock de sessão antes de escrever o PID file
        [[ "${start_content}" == *'session.lock'* ]] || exit 1
        [[ "${start_content}" == *'flock -n'* ]] || exit 1

        # Identidade de processo (PID + start time)
        [[ "${start_content}" == *'proc_start_time'* ]] || exit 1
        [[ "${start_content}" == *'process_is_owned'* ]] || exit 1
        [[ "${stop_content}" == *'process_is_owned'* ]] || exit 1

        # Transporte de áudio do guest: TCP loopback com cookie
        [[ "${start_content}" == *'module-native-protocol-tcp'* ]] || exit 1
        [[ "${start_content}" == *'auth-cookie'* ]] || exit 1
        [[ "${start_content}" == *'PULSE_COOKIE'* ]] || exit 1

        # Wine: sessão gráfica + caminho relativo preservado
        [[ "${stop_content}" != *'pkill'* ]] || exit 1
        [[ "${stop_content}" != *'lsof'* ]] || exit 1
        [[ "${stop_content}" == *'kill -TERM'* ]] || exit 1
        [[ "${stop_content}" == *'kill -KILL'* ]] || exit 1
        [[ "${wrapper_content}" == *'proot-distro login'* ]] || exit 1
        [[ "${wrapper_content}" == *'cyberdeck'* ]] || exit 1
        [[ "${wrapper_content}" == *'wine "${target}" "$@"'* ]] || exit 1
        [[ "${wrapper_content}" == *'--shared-x11'* ]] || exit 1
        [[ "${wrapper_content}" == *'--work-dir'* ]] || exit 1
        [[ "${wrapper_content}" == *'PULSE_COOKIE'* ]] || exit 1
        [[ ! -L "${HOME}/.local/bin/wine" ]] || exit 1
    )
}

test_existing_launcher_backup() {
    local home="${TEST_TMP}/backup"
    mkdir -p "${home}" || return 1
    printf 'old launcher\n' > "${home}/start-linux.sh"
    (
        export HOME="${home}"
        source "${INTERNAL}" || exit 1
        INSTALL_LOG="${home}/install.log"
        : > "${INSTALL_LOG}"
        DESKTOP_CHOICE="lxqt"
        GPU_KEY="generic"
        GPU_DRIVER_SELECTED="zink"
        GPU_FALLBACK="llvmpipe"
        generate_start_script || exit 1
        compgen -G "${home}/start-linux.sh.*.bak" >/dev/null || exit 1
    )
}

test_guest_failure_propagates() {
    local mock_bin="${TEST_TMP}/mock-bin"
    mkdir -p "${mock_bin}" || return 1
    cat > "${mock_bin}/proot-distro" <<'MOCK'
#!/usr/bin/env bash
exit 7
MOCK
    chmod +x "${mock_bin}/proot-distro"

    ! (
        export PATH="${mock_bin}:${PATH}"
        source "${INTERNAL}" || exit 1
        INSTALL_LOG="${TEST_TMP}/guest-failure.log"
        : > "${INSTALL_LOG}"
        guest_run "true"
    )
}

test_lock_is_exclusive() {
    local lock_file="${TEST_TMP}/cyberdeck-install.lock"
    (
        exec 9>"${lock_file}"
        flock -n 9 || exit 1
        ! flock -n "${lock_file}" -c 'true'
    )
}

test_integrity_hash_is_pinned() {
    local expected
    expected="$(sed -n 's/^readonly CYBERDECK_SCRIPT_SHA256="\([0-9a-f]\{64\}\)".*/\1/p' "${INSTALLER}")" || return 1
    [[ -n "${expected}" ]] || return 1
    ! grep -q '__CYBERDECK_SCRIPT_SHA256__' "${INSTALLER}" || return 1
    [[ "$(sha256sum "${INTERNAL}" | awk '{print $1}')" == "${expected}" ]] || return 1
}

test_forbidden_critical_patterns() {
    local content
    # Comentários não executam comandos: a varredura ignora linhas de
    # comentário para detectar apenas uso real dos padrões proibidos.
    content="$(cat "${INSTALLER}" "${INTERNAL}" | grep -v -E '^[[:space:]]*#')" || return 1
    [[ "${content}" != *'pkill -9'* ]] || return 1
    [[ "${content}" != *'apt-get install -y tur-repo'* ]] || return 1
    [[ "${content}" != *'pip install flask'* ]] || return 1
    [[ "${content}" != *'firefox-esr'* ]] || return 1
    [[ "${content}" != *'apt-get install -y wine32'* ]] || return 1
    [[ "${content}" != *'dpkg --add-architecture i386'* ]] || return 1
}

run_test "sintaxe dos scripts" test_syntax
run_test "canonicalização dos desktops" test_installer_desktop_contract
run_test "desktop inválido rejeitado pelo instalador" test_installer_rejects_invalid_desktop
run_test "die retorna status de falha" test_installer_die_returns_failure
run_test "URL do repositório normalizada (.git)" test_installer_normalizes_repo_url
run_test "espaço verificado antes do bootstrap" test_installer_checks_disk_space_before_bootstrap
run_test "desktop inválido rejeitado pelo script interno" test_internal_rejects_invalid_desktop
run_test "matriz de desktops e imagem pinada" test_internal_matrix_contract
run_test "pacotes de desktop são pacotes válidos" test_internal_desktop_packages_are_real_packages
run_test "x11-repo habilitado antes da instalação X11" test_internal_enables_x11_repo_before_install
run_test "matriz de GPU" test_gpu_matrix_contract
run_test "fixtures de detecção de GPU" test_gpu_detection_fixtures
run_test "geração e segurança dos launchers" test_generated_launchers
run_test "backup de launcher existente" test_existing_launcher_backup
run_test "falha guest propaga status" test_guest_failure_propagates
run_test "lock de instalação é exclusivo" test_lock_is_exclusive
run_test "SHA-256 do script interno está pinado" test_integrity_hash_is_pinned
run_test "padrões críticos proibidos" test_forbidden_critical_patterns

if python3 "${TESTS_DIR}/check_markdown_links.py"; then
    pass "links e âncoras Markdown"
else
    fail "links e âncoras Markdown"
fi

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
((FAILED == 0))
