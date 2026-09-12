#!/usr/bin/env bash
# SCRIPT: test.sh
# DESCRIPTION: Run canonical repository validation checks.
# USAGE: ./test [-h] [--no-shellcheck]
# PARAMETERS:
# -h                : show help
# --no-shellcheck   : skip shellcheck validation
# EXAMPLE: ./test
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    if [[ "$SCRIPT_SOURCE" != /* ]]; then
        SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
    fi
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF_CMD="./$(basename "$0")"

usage() {
    cat <<USAGE
Run canonical validation checks.

Usage: ${SELF_CMD} [-h] [--no-shellcheck]

Options:
  -h               Show help
  --no-shellcheck  Skip shellcheck checks
USAGE
}

run_shellcheck=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --no-shellcheck) run_shellcheck=false ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

cd "$ROOT_DIR"

./scripts/build.sh
./scripts/test-cancel-flow.sh
./scripts/test-dependency-install.sh
./scripts/test-setup-dependencies.sh
./scripts/test-flash-drive-redirect.sh
./scripts/test-ventoy-install-dialog.sh
./scripts/test-ventoy-selection.sh
./scripts/test-iso-creator.sh
./scripts/test-download-error-state.sh
./scripts/test-browser-catalog-entry.sh
./scripts/test-download-progress.sh
./scripts/test-forge-recipe.sh
./scripts/test-forge-distrodeck.sh
./scripts/test-forge-image.sh
./scripts/test-forge-nikos.sh
./scripts/test-forge-integration.sh
./scripts/test-forge-ansible.sh
./scripts/test-rpm-manifest.sh

if command -v jq >/dev/null 2>&1; then
    jq -e '.distros and (.distros | type == "array")' config.json >/dev/null
    for catalog_id in \
        Ubuntu_24_04_4_server_amd64 \
        Ubuntu_24_04_4_server_arm64 \
        Ubuntu_26_04_1_server_amd64 \
        Ubuntu_26_04_1_server_arm64 \
        Proxmox_VE_9_2_1_amd64 \
        Proxmox_VE_9_2_1_arm64 \
        OpenMediaVault_8_3_1_amd64 \
        OPNsense_26_7_dvd_amd64 \
        TrueNAS_Community_25_10_7_amd64 \
        antiX_26_i386_core; do
        jq -e --arg id "$catalog_id" \
            '.distros[] | select(.id == $id and (.url | startswith("https://")))' \
            config.json >/dev/null
    done
    jq -e '[.distros[].id] as $ids | def pos($id): $ids | index($id); (pos("Ubuntu_24_04_3_desktop_amd64") < pos("Xubuntu_24_04_4_desktop_amd64") and pos("Xubuntu_26_04_1_desktop_amd64") < pos("Ubuntu_Studio_24_04_3_amd64") and pos("MX_Linux_23_1_i386") < pos("antiX_26_i386_core") and pos("antiX_26_i386_core") < pos("antiX_23_x64_full") and pos("NixOS_24_05_GNOME_x86_64") < pos("Ubuntu_24_04_4_server_amd64") and pos("pfSense_Netgate_Installer") < pos("GParted_Live_1_5_0_1_amd64") and pos("Hirens_BootCD_PE_x64") < pos("Ubuntu_24_04_3_Surface_amd64") and pos("Xbox_Ubuntu_Server_amd64_note") < pos("RaspberryPi_OS_Bookworm_Lite_arm64_2024_10_22") and pos("Ubuntu_24_04_3_preinstalled_raspi_arm64") < pos("Armbian_OrangePi5_Jammy_current") and pos("Armbian_TVBox_Amlogic_s905x_Community") < pos("Android_x86_9_0_r2_amd64"))' config.json >/dev/null
else
    echo "warning: jq not available; skipping config schema check" >&2
fi

if $run_shellcheck; then
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "shellcheck not found. Install shellcheck or run ${SELF_CMD} --no-shellcheck" >&2
        exit 1
    fi
    mapfile -t project_shell_files < <(find . \
        -path './.git' -prune -o \
        -path './scripts/script-helpers' -prune -o \
        -path './dist' -prune -o \
        -type f -name '*.sh' -print | sort)
    shellcheck -x -e SC1091 "${project_shell_files[@]}"
fi

echo "All test checks passed."
