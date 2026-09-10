#!/usr/bin/env bash
# SCRIPT: isoforge.sh
# DESCRIPTION: Isoforge downloads Linux images, prepares Ventoy USB drives, and builds custom installable ISOs from a base ISO and recipe.
# USAGE: isoforge [OPTIONS] [COMMAND [COMMAND_OPTIONS]]
# EXAMPLE: isoforge --config ./config.json
# EXAMPLE: sudo isoforge build --recipe recipes/nikos.yml
# PARAMETERS:
#   download        Download one or more ISOs from config.json. Options: --config PATH, -h, --help.
#   burn            Prepare a Ventoy drive and copy selected ISO files to it. Options: --config PATH, -h, --help.
#   build           Build a custom installable ISO from a recipe. Options: -r/--recipe PATH, -o/--output DIR, --config PATH, --work-dir DIR, --dry-run, --smoke-test, --keep, --version, -h/--help.
#   setup           Install project dependencies. Parameters: PACKAGE. Options: -h, --help.
#   help [COMMAND]  Show top-level help or command help for download, burn, build, or setup.
#   --config PATH   Override config file path for the TUI flow.
#   --version       Print version and exit.
#   -h, --help      Show help and exit.
set -euo pipefail

# CLI Isoforge-like interface using dialog
# Steps: Select Images -> Select Drive -> Prepare Ventoy!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISOFORGE_ROOT="${ISOFORGE_ROOT:-}"
if [[ -z "$ISOFORGE_ROOT" && -f "/usr/share/isoforge/config.json" ]]; then
  ISOFORGE_ROOT="/usr/share/isoforge"
fi
if [[ -z "$ISOFORGE_ROOT" ]]; then
  # Resolve repo root so script works whether run via root-level symlink or directly
  if [[ -d "$SCRIPT_DIR/scripts/script-helpers" && -f "$SCRIPT_DIR/config.json" ]]; then
    ISOFORGE_ROOT="$SCRIPT_DIR"
  elif [[ -f "$SCRIPT_DIR/../config.json" && -d "$SCRIPT_DIR/../scripts/script-helpers" ]]; then
    ISOFORGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  else
    ISOFORGE_ROOT="$SCRIPT_DIR"
  fi
fi
REPO_ROOT="$ISOFORGE_ROOT"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [[ -f "$REPO_ROOT/inc/cli-help.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/cli-help.sh"
else
  >&2 printf "Missing required CLI help file: %s\n" "$REPO_ROOT/inc/cli-help.sh"
  exit 1
fi

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  >&2 printf "Missing required helper library: %s\n" "$SCRIPT_HELPERS_DIR/helpers.sh"
  >&2 printf "Please install project submodules (e.g. run 'git submodule update --init --recursive') and retry.\n"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help dialog file os json deps
if [[ ! -f "$REPO_ROOT/inc/download-state.sh" ]]; then
  >&2 printf "Missing required download state helper: %s\n" "$REPO_ROOT/inc/download-state.sh"
  >&2 printf "Please reinstall Isoforge or restore the missing file and retry.\n"
  exit 1
fi
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/download-state.sh"

CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config.json}"

usage() {
  isoforge_show_help
}

VERSION_FILE="$REPO_ROOT/VERSION"
VERSION="${ISOFORGE_VERSION:-}"
if [[ -z "$VERSION" && -f "$VERSION_FILE" ]]; then
  VERSION="$(cat "$VERSION_FILE" 2>/dev/null || true)"
fi
VERSION="${VERSION:-0.1.0}"

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      build|forge)
        shift
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
          isoforge_show_help build
          exit 0
        fi
        exec "$REPO_ROOT/inc/forge.sh" "$@"
        ;;
      download)
        shift
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
          isoforge_show_help download
          exit 0
        fi
        exec "$REPO_ROOT/inc/download.sh" "$@"
        ;;
      burn)
        shift
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
          isoforge_show_help burn
          exit 0
        fi
        printf 'The interactive Ventoy workflow is used for burning.
' >&2
        exec "$REPO_ROOT/inc/isoforge.sh"
        ;;
      setup)
        shift
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
          isoforge_show_help setup
          exit 0
        fi
        exec "$REPO_ROOT/inc/setup.sh" "$@"
        ;;
      help)
        shift
        isoforge_show_help "${1:-}"
        exit $?
        ;;
      --config)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          printf "Missing value for --config\n" >&2
          usage
          exit 2
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      --version) echo "$VERSION"; exit 0;;
      -h|--help) usage; exit 0;;
      *) printf "Unknown argument: %s\n" "$1" >&2; usage; exit 2;;
    esac
  done
}

# Always restore a clean terminal UI when exiting (including Cancel/interrupt).
reset_tui() { tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true; clear; }

SELECTED_IMAGE=""
SELECTED_DEVICE=""
DOWNLOAD_DIR=""
DEVICE_FILTER="usb"
# Multi-image (Ventoy) and background support
declare -a SELECTED_IMAGES=()
SELECTED_BACKGROUND=""

restore_main_menu_snapshot() {
  local saved_image="$1"
  local saved_device="$2"
  local saved_background="$3"
  SELECTED_IMAGE="$saved_image"
  SELECTED_DEVICE="$saved_device"
  SELECTED_BACKGROUND="$saved_background"
  shift 3
  SELECTED_IMAGES=("$@")
}

run_main_menu_action() {
  local action_name="$1"
  local saved_image="$SELECTED_IMAGE"
  local saved_device="$SELECTED_DEVICE"
  local saved_background="$SELECTED_BACKGROUND"
  local -a saved_images=("${SELECTED_IMAGES[@]}")

  # Canceling a sub-flow should always land back on the main page with the
  # last committed selections intact rather than leaking partial state.
  if "$action_name"; then
    return 0
  else
    local status=$?
    restore_main_menu_snapshot "$saved_image" "$saved_device" "$saved_background" "${saved_images[@]}"
    return "$status"
  fi
}

require_tool() {
  local t="$1"
  if ! command -v "$t" >/dev/null 2>&1; then
    print_error "$t is required but not installed. Run ./setup.sh."
    exit 1
  fi
}

is_http_override_enabled() {
  [[ "${ALLOW_INSECURE_HTTP_DOWNLOADS:-0}" == "1" ]]
}

is_allowed_download_url() {
  local url="$1"
  if [[ "$url" == https://* ]]; then
    return 0
  fi
  if [[ "$url" == http://* ]]; then
    is_http_override_enabled
    return
  fi
  return 1
}

open_browser_catalog_source() {
  local id="$1" browser_url="$2"

  if ! is_browser_url "$browser_url"; then
    dialog --title "Unsupported browser URL" --msgbox \
      "The selected source does not provide a safe HTTPS browser URL." 7 64
    return 1
  fi
  if ! dialog --title "Open authenticated source" --yesno \
    "${id} requires authentication and cannot be downloaded directly.\n\nOpen the vendor page in your browser now?" 10 72; then
    return 2
  fi
  if ! open_browser_url "$browser_url"; then
    dialog --title "Browser unavailable" --msgbox \
      "Could not open a browser. Open this URL manually:\n\n${browser_url}" 10 76
    return 1
  fi
  dialog --title "Browser opened" --msgbox \
    "Complete the vendor download in your browser. When it finishes, return here and choose Local ISO files." 9 76
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi
  require_tool jq

  # download dir
  DOWNLOAD_DIR=$(jq -r '.download_dir // empty' "$CONFIG_FILE")
  if [[ -z "$DOWNLOAD_DIR" || "$DOWNLOAD_DIR" == "null" ]]; then
    DOWNLOAD_DIR="$HOME/Downloads/iso_images"
  fi
  # expand ~ at start
  [[ "$DOWNLOAD_DIR" == ~* ]] && DOWNLOAD_DIR="${DOWNLOAD_DIR/#~/$HOME}"

  # device filter (usb|any)
  DEVICE_FILTER=$(jq -r '.block_device_filter // "usb"' "$CONFIG_FILE")
}

# Return success when the selected package manager will require sudo.
package_manager_requires_sudo() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || return 1
  command -v apt-get >/dev/null 2>&1 || \
    command -v dnf >/dev/null 2>&1 || \
    command -v pacman >/dev/null 2>&1
}

# Ask for permission and authenticate before a dialog owns the terminal. The
# dependency helper invokes sudo itself; pre-validating here keeps its password
# prompt from being hidden behind an installation UI.
prepare_dependency_installation() {
  local packages="$*"
  local prompt="Isoforge needs to install:\n\n${packages}\n\nContinue?"

  if command -v dialog >/dev/null 2>&1; then
    dialog_init
    dialog --title "Install Dependencies" --defaultno --yesno "$prompt" 12 "$DIALOG_WIDTH" || return 1
  else
    [[ -t 0 ]] || {
      print_error "Dependencies are missing. Run ./setup in an interactive terminal."
      return 1
    }
    local reply
    read -r -p "Isoforge needs to install: ${packages}. Continue? [y/N] " reply || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || return 1
  fi

  if package_manager_requires_sudo; then
    if ! command -v sudo >/dev/null 2>&1; then
      print_error "A supported package manager requires sudo, but sudo is not available. Run ./setup as an administrator."
      return 1
    fi
    sudo -v || {
      print_error "Administrator authentication failed. Dependencies were not installed."
      return 1
    }
  fi
}

# Show the package manager's real output in a dialog and retain it in a log.
# This deliberately avoids a made-up percentage: package managers do not
# expose a portable progress value, and a hidden sudo prompt used to make the
# old gauge loop forever.
deps_install_with_dialog() {
  local log="$REPO_ROOT/.deps_install.log"
  : >"$log"
  dialog_init
  local errexit_was_on=0
  [[ $- == *e* ]] && errexit_was_on=1
  set +e
  install_dependencies "$@" 2>&1 | tee -a "$log" | \
    dialog --title "Installing Dependencies" --programbox 20 "$DIALOG_WIDTH"
  local -a statuses=("${PIPESTATUS[@]}")
  (( errexit_was_on )) && set -e
  return "${statuses[0]}"
}

# Install required tools if missing using script-helpers.
ensure_deps() {
  local log="$REPO_ROOT/.deps_install.log"
  : >"$log"

  # Ensure dialog exists first so the remaining install can display live output.
  if ! command -v dialog >/dev/null 2>&1; then
    prepare_dependency_installation dialog || return 1
    if ! install_dependencies dialog 2>&1 | tee -a "$log"; then
      print_error "Failed to install dialog. Details were saved to: $log"
      return 1
    fi
    if ! command -v dialog >/dev/null 2>&1; then
      print_error "dialog is still unavailable after installation. Details were saved to: $log"
      return 1
    fi
  fi

  # 2) Compute remaining missing dependencies
  local pkgs=()
  command -v jq >/dev/null 2>&1       || pkgs+=(jq)
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    pkgs+=(curl wget)
  fi
  command -v lsblk >/dev/null 2>&1    || pkgs+=(util-linux)
  command -v dd    >/dev/null 2>&1    || pkgs+=(coreutils)
  command -v file  >/dev/null 2>&1    || pkgs+=(file)
  command -v rsync >/dev/null 2>&1    || pkgs+=(rsync)
  command -v unzip >/dev/null 2>&1    || pkgs+=(unzip)
  command -v less  >/dev/null 2>&1    || pkgs+=(less)
  command -v xz    >/dev/null 2>&1    || pkgs+=(xz xz-utils)
  command -v gzip  >/dev/null 2>&1    || pkgs+=(gzip)

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    prepare_dependency_installation "${pkgs[@]}" || return 1
    if ! deps_install_with_dialog "${pkgs[@]}"; then
      dialog --title "Dependencies" --msgbox \
        "Dependencies failed to install.\n\nYou can review the log at:\n$log" 10 60
      return 1
    fi
  fi
}

ensure_dialog() {
  check_if_dialog_installed || {
    print_error "Dialog not installed. Run ./setup.sh"
    exit 1
  }
}

title() { echo "Isoforge (CLI) — iso-forge"; }

show_summary() {
  local img="<not selected>"
  local dev="${SELECTED_DEVICE:+/dev/$SELECTED_DEVICE}"
  [[ -z "$dev" ]] && dev="<not selected>"
  local multi_count=${#SELECTED_IMAGES[@]}
  [[ $multi_count -gt 0 ]] && img="${multi_count} image(s) (Ventoy)"
  local bg="${SELECTED_BACKGROUND:-<none>}"
  printf "Images: %s\nDrive: %s\nBackground: %s\n" "$img" "$dev" "$bg"
  if has_last_download_error; then
    printf "\n%s\n" "$(last_download_error_summary)"
  fi
}

select_image_source() {
  dialog_init
  local choice
  choice=$(dialog --stdout --title "$(title)" --menu "Select image source" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 \
    download "Choose from curated distros" \
    local    "Choose local ISO files" \
    back     "Back") || return 1

  case "$choice" in
    download) select_images_from_config_multi ;;
    local)    select_images_local_multi       ;;
    back)            return 0                        ;;
  esac
}

# Multi-select from config: download chosen ISOs, then select them
select_images_from_config_multi() {
  dialog_init
  load_config
  create_directory "$DOWNLOAD_DIR" >/dev/null || true
  mapfile -t rows < <(jq -r '.distros[] | "\(.id)\t\(.label)\t\(.url // \"\")\t\(.browser_url // \"\")"' "$CONFIG_FILE")
  if [[ ${#rows[@]} -eq 0 ]]; then
    dialog --title "No distros" --msgbox "No distros defined in config.json" 8 50
    return 1
  fi
  local items=() prev_cat="" id label url cat
  distro_category() {
    local id="$1" label="$2" lower="${1,,} ${2,,}"
    if [[ "$lower" == *"raspberry pi"* || "$id" == RaspberryPi_* ]]; then echo "SBC — Raspberry Pi"; return; fi
    if [[ "$id" == Armbian_* || "$lower" == *"armbian"* ]]; then echo "SBC — Armbian / TV Box"; return; fi
    if [[ "$lower" == *"android-x86"* || "$lower" == *"bliss os"* || "$lower" == *"lineageos"* || "$lower" == *"grapheneos"* ]]; then echo "Android / Tablet"; return; fi
    if [[ "$lower" == *"gparted"* || "$lower" == *"rescue"* || "$lower" == *"hiren"* || "$lower" == *"clonezilla"* ]]; then echo "Utilities / Repair"; return; fi
    if [[ "$lower" == *"surface"* || "$lower" == *"xbox"* ]]; then echo "Surface / Xbox"; return; fi
    if [[ "$lower" == *"server"* || "$lower" == *"proxmox"* || "$lower" == *"openmediavault"* || "$lower" == *"opnsense"* || "$lower" == *"pfsense"* || "$lower" == *"truenas"* ]]; then echo "Server / Infrastructure"; return; fi
    echo "Desktop / Linux"
  }
  for line in "${rows[@]}"; do
    id="${line%%$'\t'*}"; rest="${line#*$'\t'}"; label="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; url="${rest%%$'\t'*}"
    cat=$(distro_category "$id" "$label")
    if [[ "$cat" != "$prev_cat" ]]; then
      items+=("hdr_${cat// /_}" "==== $cat ====" off)
      prev_cat="$cat"
    fi
    items+=("$id" "$label" off)
  done
  local chosen
  chosen=$(dialog --stdout --title "Choose Distros (multi)" --checklist "Pick one or more to download" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || return 1
  chosen=$(sed 's/\"//g' <<<"$chosen")
  [[ -z "$chosen" ]] && return 1

  pushd "$DOWNLOAD_DIR" >/dev/null
  SELECTED_IMAGES=()
  local -a skipped_insecure=()
  local -a skipped_unsupported=()
  local id url browser_url output path errs=0 download_failed=0 browser_handoffs=0 browser_status
  for id in $chosen; do
    [[ "$id" == hdr_* ]] && continue
    browser_url=$(jq -r --arg id "$id" '.distros[] | select(.id==$id) | .browser_url // empty' "$CONFIG_FILE")
    if [[ -n "$browser_url" ]]; then
      if open_browser_catalog_source "$id" "$browser_url"; then
        browser_handoffs=$((browser_handoffs+1))
      else
        browser_status=$?
        if (( browser_status != 2 )); then
          errs=$((errs+1))
        fi
      fi
      continue
    fi
    url=$(jq -r --arg id "$id" '.distros[] | select(.id==$id) | .url // empty' "$CONFIG_FILE")
    [[ -z "$url" || "$url" == "null" ]] && { errs=$((errs+1)); continue; }
    if [[ "$url" != https://* && "$url" != http://* ]]; then
      errs=$((errs+1))
      skipped_unsupported+=("$id")
      continue
    fi
    if ! is_allowed_download_url "$url"; then
      errs=$((errs+1))
      skipped_insecure+=("$id")
      continue
    fi
    output=$(derive_download_output_name "$url")
    if [[ ! -f "$output" ]]; then
      if ! download_file_with_error_tracking "$url" "$output" "multi-download" "$id"; then
        errs=$((errs+1))
        download_failed=1
      fi
    fi
    path="$DOWNLOAD_DIR/$output"
    if [[ -f "$path" ]]; then SELECTED_IMAGES+=("$path"); fi
  done
  popd >/dev/null
  if (( errs > 0 )); then
    local detail=""
    local failure_note="If a download fails, the latest failure remains visible in the main status panel."
    if (( download_failed == 1 )) && has_last_download_error; then
      failure_note="The latest download failure remains visible in the main status panel."
    fi
    if [[ ${#skipped_insecure[@]} -gt 0 ]]; then
      detail="${detail}\nSkipped insecure (HTTP) selections: ${skipped_insecure[*]}"
      detail="${detail}\nHint: set ALLOW_INSECURE_HTTP_DOWNLOADS=1 only if you explicitly accept insecure downloads."
    fi
    if [[ ${#skipped_unsupported[@]} -gt 0 ]]; then
      detail="${detail}\nSkipped unsupported URL selections: ${skipped_unsupported[*]}"
    fi
    dialog --title "Download completed with warnings" --msgbox \
      "Some selected items could not be processed (${errs}).\nThis may be due to missing URLs, unsupported URL schemes, insecure URL rejection, or download failures.\nOnly successfully downloaded files were kept in the selection.\n\n${failure_note}${detail}" 16 74
  fi
  if [[ ${#SELECTED_IMAGES[@]} -eq 1 ]]; then
    SELECTED_IMAGE="${SELECTED_IMAGES[0]}"
  elif [[ ${#SELECTED_IMAGES[@]} -gt 1 ]]; then
    SELECTED_IMAGE=""
  elif (( browser_handoffs > 0 )); then
    return 1
  else
    dialog --title "Download" --msgbox "No files downloaded/selected." 7 40
    return 1
  fi
}

# Multi-select local ISOs from download directory
select_images_local_multi() {
  dialog_init
  load_config
  create_directory "$DOWNLOAD_DIR" >/dev/null || true
  mapfile -t files < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -iname "*.iso" 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    dialog --title "No ISOs" --msgbox "No ISO files found in $DOWNLOAD_DIR. Run ./download to fetch images first." 9 70
    return 1
  fi
  local items=()
  local p base
  for p in "${files[@]}"; do
    base=$(basename "$p")
    items+=("$p" "$base" off)
  done
  local selected
  selected=$(dialog --stdout --title "Select ISOs (Ventoy)" --checklist "Choose one or more images to copy via Ventoy" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || return 1
  selected=$(sed 's/\"//g' <<<"$selected")
  SELECTED_IMAGES=()
  for p in $selected; do SELECTED_IMAGES+=("$p"); done
  if [[ ${#SELECTED_IMAGES[@]} -eq 1 ]]; then
    SELECTED_IMAGE="${SELECTED_IMAGES[0]}"
  elif [[ ${#SELECTED_IMAGES[@]} -gt 1 ]]; then
    SELECTED_IMAGE=""
  fi
}

select_image_local() {
  dialog_init
  local start_dir="${SELECTED_IMAGE:-$HOME}"
  local iso
  iso=$(dialog --stdout --title "$(title) — Select ISO" --fselect "$start_dir/" "$DIALOG_HEIGHT" "$DIALOG_WIDTH") || return 1
  if [[ -z "$iso" ]]; then return 1; fi
  if [[ "${iso,,}" != *.iso ]]; then
    dialog --title "Invalid file" --msgbox "Selected file is not an .iso" 8 50
    return 1
  fi
  SELECTED_IMAGE="$iso"
}

select_image_from_config() {
  dialog_init
  load_config
  create_directory "$DOWNLOAD_DIR" >/dev/null || true

  # Build grouped menu options from config.json
  mapfile -t rows < <(jq -r '.distros[] | "\(.id)\t\(.label)\t\(.url // \"\")\t\(.browser_url // \"\")"' "$CONFIG_FILE")
  if [[ ${#rows[@]} -eq 0 ]]; then
    dialog --title "No distros" --msgbox "No distros defined in config.json" 8 50
    return 1
  fi
  # Flatten into tag/label alternating items for dialog, with headers
  local items=() prev_cat="" id label url cat
  distro_category() {
    local id="$1" label="$2" lower="${1,,} ${2,,}"
    if [[ "$lower" == *"raspberry pi"* || "$id" == RaspberryPi_* ]]; then echo "SBC — Raspberry Pi"; return; fi
    if [[ "$id" == Armbian_* || "$lower" == *"armbian"* ]]; then echo "SBC — Armbian / TV Box"; return; fi
    if [[ "$lower" == *"android-x86"* || "$lower" == *"bliss os"* || "$lower" == *"lineageos"* || "$lower" == *"grapheneos"* ]]; then echo "Android / Tablet"; return; fi
    if [[ "$lower" == *"gparted"* || "$lower" == *"rescue"* || "$lower" == *"hiren"* || "$lower" == *"clonezilla"* ]]; then echo "Utilities / Repair"; return; fi
    if [[ "$lower" == *"surface"* || "$lower" == *"xbox"* ]]; then echo "Surface / Xbox"; return; fi
    if [[ "$lower" == *"server"* || "$lower" == *"proxmox"* || "$lower" == *"openmediavault"* || "$lower" == *"opnsense"* || "$lower" == *"pfsense"* || "$lower" == *"truenas"* ]]; then echo "Server / Infrastructure"; return; fi
    echo "Desktop / Linux"
  }
  for line in "${rows[@]}"; do
    id="${line%%$'\t'*}"; rest="${line#*$'\t'}"; label="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; url="${rest%%$'\t'*}"
    cat=$(distro_category "$id" "$label")
    if [[ "$cat" != "$prev_cat" ]]; then
      items+=("hdr_${cat// /_}" "==== $cat ====")
      prev_cat="$cat"
    fi
    items+=("$id" "$label")
  done

  local chosen
  while true; do
    chosen=$(dialog --stdout --title "$(title) — Choose Distro" --menu "Pick a distro to download" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || return 1
    [[ "$chosen" == hdr_* ]] && continue
    break
  done

  local url browser_url output path
  browser_url=$(jq -r --arg id "$chosen" '.distros[] | select(.id==$id) | .browser_url // empty' "$CONFIG_FILE")
  if [[ -n "$browser_url" ]]; then
    open_browser_catalog_source "$chosen" "$browser_url"
    return 1
  fi
  url=$(jq -r --arg id "$chosen" '.distros[] | select(.id==$id) | .url // empty' "$CONFIG_FILE")
  if [[ -z "$url" || "$url" == "null" ]]; then
    dialog --title "Error" --msgbox "No URL found for selected distro." 8 50
    return 1
  fi
  if [[ "$url" != https://* && "$url" != http://* ]]; then
    dialog --title "Unsupported URL" --msgbox \
      "The selected distro uses an unsupported URL scheme.\nPlease update config.json to use https:// or http://." 8 72
    return 1
  fi
  if ! is_allowed_download_url "$url"; then
    dialog --title "Insecure URL blocked" --msgbox \
      "The selected distro uses an insecure HTTP URL and was blocked by default.\nSet ALLOW_INSECURE_HTTP_DOWNLOADS=1 only if you explicitly accept insecure downloads." 9 74
    return 1
  fi

  pushd "$DOWNLOAD_DIR" >/dev/null
  # Determine output filename (mirrors scripts/lib/file.sh logic)
  output=$(derive_download_output_name "$url")

  if ! download_file_with_error_tracking "$url" "$output" "single-download" "$chosen"; then
    popd >/dev/null
    return 1
  fi

  path="$DOWNLOAD_DIR/$output"
  if is_valid_iso "$path"; then
    SELECTED_IMAGE="$path"
    print_success "Downloaded: $path"
  else
    dialog --title "Warning" --msgbox "Downloaded file is not detected as ISO: $path" 9 60
    SELECTED_IMAGE="$path"
  fi
  popd >/dev/null
}

device_capacity_bytes() {
  local dev="$1" bytes
  bytes=$(lsblk -dn -b -o SIZE "/dev/$dev" 2>/dev/null | tr -d '[:space:]')
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$bytes"
}

validate_ventoy_device() {
  local dev="$1"
  shift
  local -a prefix=("$@")
  local bytes
  bytes=$(device_capacity_bytes "${dev#/dev/}" || true)
  if [[ -z "$bytes" || "$bytes" == 0 ]]; then
    dialog --title "Drive unavailable" --msgbox       "$dev reports no usable capacity. Reconnect the USB drive, wait for it to appear with a non-zero size, then select it again." 9 72
    return 1
  fi
  if ! "${prefix[@]}" dd if="$dev" of=/dev/null bs=1 count=1 status=none 2>/dev/null; then
    dialog --title "Drive unavailable" --msgbox       "Isoforge cannot read $dev even with administrator privileges. Reconnect the drive or select a different USB device." 9 72
    return 1
  fi
}

select_drive() {
  dialog_init
  local rows raw dev type size model tran rm ro
  raw=$(lsblk -dn -o NAME,TYPE,SIZE,MODEL,TRAN,RM,RO -P)
  rows=()
  while IFS= read -r line; do
    # shellcheck disable=SC2001
    dev=$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<<"$line")
    type=$(sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' <<<"$line")
    size=$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<<"$line")
    model=$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<<"$line")
    tran=$(sed -n 's/.*TRAN="\([^"]*\)".*/\1/p' <<<"$line")
    rm=$(sed -n 's/.*RM="\([^"]*\)".*/\1/p' <<<"$line")
    ro=$(sed -n 's/.*RO="\([^"]*\)".*/\1/p' <<<"$line")

    [[ "$type" != "disk" ]] && continue
    if [[ "$DEVICE_FILTER" == "usb" ]]; then
      [[ "$tran" != "usb" && "$rm" != "1" ]] && continue
    fi

    rows+=("$dev" "$size ${model:-} [${tran:-n/a}] RO:${ro}")
  done <<<"$raw"

  if [[ ${#rows[@]} -eq 0 ]]; then
    dialog --title "No drives" --msgbox "No suitable drives found (filter: $DEVICE_FILTER)." 8 60
    return 1
  fi

  local chosen
  chosen=$(dialog --stdout --title "$(title) — Select Drive" --menu "Choose destination drive (data will be destroyed)" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${rows[@]}") || return 1

  # Verify not mounted
  if lsblk "/dev/$chosen" -o MOUNTPOINT -n | grep -q "/"; then
    dialog --title "Drive mounted" --msgbox \
      "Selected drive appears to have mounted partitions.\nPlease unmount all partitions and try again." 9 70
    return 1
  fi

  SELECTED_DEVICE="$chosen"
}

flash_confirm() {
  dialog --stdout --title "Confirm Flash" --yesno \
    "Images:\n  $( if [[ ${#SELECTED_IMAGES[@]} -gt 1 ]]; then echo "${#SELECTED_IMAGES[@]} selected (Ventoy)"; else echo "${SELECTED_IMAGE:-<not selected>}"; fi )\n\nDrive:\n  /dev/$SELECTED_DEVICE\n\nAll data on the drive will be destroyed. Proceed?" 12 70
}

ensure_flash_drive_selected() {
  if [[ -n "${SELECTED_DEVICE:-}" ]]; then
    return 0
  fi

  dialog --title "Missing selection" --msgbox "Please select a drive first." 8 60
  select_drive || return 1
}

flash_image() {
  dialog_init
  ensure_flash_drive_selected || return 1
  if [[ ${#SELECTED_IMAGES[@]} -gt 0 ]]; then
    flash_with_ventoy
    return $?
  fi
  dialog --title "Missing selection" --msgbox "Please select one or more ISO files first." 8 60
  return 1

}

# --- Ventoy support ---
flash_with_ventoy() {
  if [[ ${#SELECTED_IMAGES[@]} -eq 0 ]]; then return 1; fi
  ensure_ventoy_available || return 1
  local dev="/dev/$SELECTED_DEVICE"
  local prefix=(); command -v sudo >/dev/null 2>&1 && prefix=(sudo)
  flash_confirm || return 1

  # Authenticate immediately after Isoforge's destructive-action confirmation,
  # before any validation or Ventoy command touches the selected device.
  if (( EUID != 0 )); then
    sudo -v || {
      dialog --title "Ventoy" --msgbox "Administrator authentication failed. Ventoy was not installed." 7 64
      return 1
    }
  fi
  validate_ventoy_device "$dev" "${prefix[@]}" || return 1

  # Ventoy owns a safety confirmation of its own. Run it in the terminal so
  # its output and y/n prompt remain native and readable, rather than hiding
  # them behind a dialog control or answering on the user's behalf.
  dialog --title "Ventoy confirmation" --msgbox \
    "Ventoy will now continue in the terminal and ask for its own confirmation.\n\nReview its device name carefully, answer there, then return here when it exits." 10 72
  clear
  printf 'Starting Ventoy for %s. Follow its terminal prompt.\n\n' "$dev"
  local errexit_was_on=0
  [[ $- == *e* ]] && errexit_was_on=1
  set +e
  "${prefix[@]}" bash "$VENTOY_BIN" -I -g "$dev"
  local vstatus=$?
  (( errexit_was_on )) && set -e
  if { : </dev/tty; } 2>/dev/null; then
    printf '\nVentoy exited with status %s. Press Enter to return to Isoforge. ' "$vstatus"
    read -r _ </dev/tty || true
  fi
  if [[ "$vstatus" -ne 0 ]]; then
    dialog --title "Ventoy" --msgbox "Ventoy installation failed (exit $vstatus). Review the installer output above." 8 72
    return 1
  fi
  local part mnt
  part=$(
    lsblk -ln -b -o NAME,TYPE,SIZE,LABEL,FSTYPE "/dev/$SELECTED_DEVICE" | awk '
      $2=="part" {
        name=$1; size=$3; label=$4; fstype=$5;
        if (label != "VTOYEFI" && fstype != "vfat" && size > best_size) {
          best_size=size; best=name;
        }
        if (size > max_size) {
          max_size=size; max=name;
        }
      }
      END { if (best != "") print best; else print max }
    '
  )
  if [[ -z "$part" ]]; then
    dialog --title "Ventoy" --msgbox "Could not locate Ventoy data partition." 7 60
    return 1
  fi
  mnt=$(lsblk -no MOUNTPOINT "/dev/$part" | head -1)
  if [[ -z "$mnt" ]]; then
    mnt="$REPO_ROOT/.mnt_ventoy"; mkdir -p "$mnt"
    if ! "${prefix[@]}" mount "/dev/$part" "$mnt"; then
      dialog --title "Ventoy" --msgbox "Failed to mount /dev/$part. Ensure exFAT support is installed (exfatprogs/exfat-utils)." 9 70
      return 1
    fi
  fi
  if [[ -n "$SELECTED_BACKGROUND" && -f "$SELECTED_BACKGROUND" ]]; then
    apply_ventoy_background "$mnt" "$SELECTED_BACKGROUND" "${prefix[@]}" || return 1
  fi
  if ! ensure_space_or_prune "$mnt"; then return 1; fi
  copy_isos_to_ventoy "$mnt" "${prefix[@]}" || return 1
  sync || true
  dialog --title "Success" --msgbox "Ventoy prepared and ISOs copied successfully." 7 60
}

ensure_ventoy_available() {
  VENTOY_BIN=""
  local cand
  for cand in "$REPO_ROOT/ventoy/Ventoy2Disk.sh" "$REPO_ROOT/tools/ventoy/Ventoy2Disk.sh" "$REPO_ROOT/Ventoy2Disk.sh"; do
    [[ -x "$cand" ]] && VENTOY_BIN="$cand" && break
  done
  if [[ -z "$VENTOY_BIN" ]] && command -v Ventoy2Disk.sh >/dev/null 2>&1; then
    VENTOY_BIN=$(command -v Ventoy2Disk.sh)
  fi
  if [[ -z "$VENTOY_BIN" ]]; then
    # Try to install via system package manager first
    if command -v apt-get >/dev/null 2>&1; then
      print_info "Installing ventoy via apt-get ..."
      if sudo apt-get update && sudo apt-get install -y ventoy; then
        if command -v Ventoy2Disk.sh >/dev/null 2>&1; then VENTOY_BIN=$(command -v Ventoy2Disk.sh); fi
      fi
    elif command -v dnf >/dev/null 2>&1; then
      print_info "Installing ventoy via dnf ..."
      sudo dnf install -y ventoy || true
      if command -v Ventoy2Disk.sh >/dev/null 2>&1; then VENTOY_BIN=$(command -v Ventoy2Disk.sh); fi
    elif command -v pacman >/dev/null 2>&1; then
      print_info "Installing ventoy via pacman ..."
      sudo pacman -S --noconfirm ventoy || true
      if command -v Ventoy2Disk.sh >/dev/null 2>&1; then VENTOY_BIN=$(command -v Ventoy2Disk.sh); fi
    fi
  fi
  if [[ -z "$VENTOY_BIN" ]]; then
    # Download latest Ventoy release from GitHub
    print_info "Downloading Ventoy (latest) ..."
    local api="https://api.github.com/repos/ventoy/Ventoy/releases/latest"
    local tag ver url tmpdir tarball outdir
    tmpdir="$(mktemp -d)"
    if curl -fsSL "$api" -o "$tmpdir/latest.json"; then
      tag=$(jq -r .tag_name "$tmpdir/latest.json" 2>/dev/null || echo "")
      ver="${tag#v}"
      if [[ -n "$ver" ]]; then
        url="https://github.com/ventoy/Ventoy/releases/download/${tag}/ventoy-${ver}-linux.tar.gz"
        mkdir -p "$REPO_ROOT/ventoy"
        if curl -fL "$url" -o "$tmpdir/ventoy.tgz"; then
          tar -xzf "$tmpdir/ventoy.tgz" -C "$REPO_ROOT/ventoy" || true
          outdir=$(find "$REPO_ROOT/ventoy" -maxdepth 1 -type d -name "ventoy-*" | head -1)
          if [[ -x "$outdir/Ventoy2Disk.sh" ]]; then
            VENTOY_BIN="$outdir/Ventoy2Disk.sh"
          fi
        fi
      fi
    fi
    rm -rf "$tmpdir"
  fi
  if [[ -z "$VENTOY_BIN" ]]; then
    dialog --title "Ventoy not found" --msgbox "Could not locate or auto-install Ventoy.\nPlease install Ventoy and ensure Ventoy2Disk.sh is available.\nRef: https://www.ventoy.net/en/download.html" 11 70
    return 1
  fi
  return 0
}

apply_ventoy_background() {
  local mnt="$1" img="$2"
  shift 2
  local -a prefix=("$@")
  local vdir="$mnt/ventoy/theme/default"
  local ext="${img##*.}"; ext="${ext,,}"
  case "$ext" in
    jpg|jpeg|png|tga) :;;
    *) dialog --title "Background" --msgbox "Unsupported image format: .$ext. Use jpg/png/tga." 8 60; return 1;;
  esac
  local bg="$vdir/background.$ext"

  # The Ventoy data partition is normally mounted by sudo and therefore owned
  # by root. Keep every write on that mounted filesystem on the same privilege
  # path; shell redirections are replaced with tee so they are elevated too.
  "${prefix[@]}" mkdir -p "$vdir" || return 1
  "${prefix[@]}" cp -f "$img" "$bg" || return 1
  printf 'desktop-image: "background.%s"\ntitle-text: "Ventoy"\n' "$ext" | \
    "${prefix[@]}" tee "$vdir/theme.txt" >/dev/null || return 1
  "${prefix[@]}" mkdir -p "$mnt/ventoy" || return 1
  printf '%s\n' '{' '  "theme": {' '    "file": "/ventoy/theme/default/theme.txt",'     '    "gfxmode": "auto",' '    "display_mode": "GUI"' '  }' '}' | \
    "${prefix[@]}" tee "$mnt/ventoy/ventoy.json" >/dev/null || return 1
}

ensure_space_or_prune() {
  local mnt="$1"
  local total=0 f size
  for f in "${SELECTED_IMAGES[@]}"; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    total=$((total + size))
  done
  local avail_kb; avail_kb=$(df -Pk "$mnt" | awk 'END{print $4}')
  local avail=$((avail_kb * 1024))
  if (( total <= avail )); then return 0; fi
  local items=()
  for f in "${SELECTED_IMAGES[@]}"; do items+=("$f" "$(basename "$f")" on); done
  local sel; sel=$(dialog --stdout --title "Insufficient space" --checklist "Available: $((avail/1024/1024)) MiB\nRequired: $((total/1024/1024)) MiB\nDeselect some ISOs:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || return 1
  sel=$(sed 's/\"//g' <<<"$sel")
  local new=(); for f in $sel; do new+=("$f"); done
  [[ ${#new[@]} -eq 0 ]] && return 1
  SELECTED_IMAGES=("${new[@]}")
  # recheck
  total=0; for f in "${SELECTED_IMAGES[@]}"; do size=$(stat -c %s "$f" 2>/dev/null || echo 0); total=$((total + size)); done
  (( total <= avail )) || ensure_space_or_prune "$mnt"
}

copy_isos_to_ventoy() {
  local mnt="$1"
  shift
  local -a prefix=("$@")
  local f
  for f in "${SELECTED_IMAGES[@]}"; do
    local base; base=$(basename "$f")
    if command -v rsync >/dev/null 2>&1; then
      "${prefix[@]}" rsync -h --progress "$f" "$mnt/$base" || return 1
    else
      "${prefix[@]}" cp -v "$f" "$mnt/$base" || return 1
    fi
  done
}

preview_background_image() {
  local img="$1" viewer=""
  for viewer in "$(command -v image-view 2>/dev/null || true)" \
    "$REPO_ROOT/image-view/image-view" "$REPO_ROOT/image-view/bin/image-view"; do
    [[ -n "$viewer" && -x "$viewer" ]] && break
    viewer=""
  done

  if [[ -z "$viewer" ]]; then
    ensure_image_view_available
    for viewer in "$REPO_ROOT/image-view/image-view" "$REPO_ROOT/image-view/bin/image-view"; do
      [[ -x "$viewer" ]] && break || viewer=""
    done
  fi

  if [[ -n "$viewer" ]] && { : </dev/tty; } 2>/dev/null; then
    dialog --title "Background preview" --msgbox \
      "The preview will open in the terminal now.\n\nUse Left/Right to browse nearby images and q when you are ready to return here." 10 72
    clear
    # Gallery mode deliberately stays open until q; the single-image command
    # renders once then exits, allowing dialog to erase the preview immediately.
    "$viewer" -g "$img" </dev/tty >/dev/tty 2>/dev/tty || return 1
    return 0
  fi

  if command -v chafa >/dev/null 2>&1; then
    local err_file chafa_rc emsg
    err_file="$(mktemp)"
    set +e
    chafa "$img" 2>"$err_file" | less -R
    chafa_rc=${PIPESTATUS[0]}
    set -e
    if [[ $chafa_rc -ne 0 ]]; then
      emsg=$(cat "$err_file")
      rm -f "$err_file"
      dialog --title "chafa error" --msgbox "Failed to preview image with chafa.\n\nError:\n${emsg}" 12 70
      return 1
    fi
    rm -f "$err_file"
    return 0
  fi

  dialog --title "Preview unavailable" --msgbox \
    "image-view and chafa are unavailable, so this image cannot be previewed here." 8 72
  return 1
}

select_background_image() {
  dialog_init
  local start_dir="${DOWNLOAD_DIR:-$HOME}"
  local bundled_dir="$REPO_ROOT/assets/ventoy"
  local choice img lower retry

  while true; do
    choice=$(dialog --stdout --title "Select Ventoy Background" --menu \
      "Choose a bundled background or a custom image" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 \
      isoforge "IsoForge — dark forge" \
      nikos "NikOS — dark slate" \
      custom "Choose a jpg/png/tga file") || return 1
    case "$choice" in
      isoforge) img="$bundled_dir/isoforge-background.png" ;;
      nikos)    img="$bundled_dir/nikos-background.png" ;;
      custom)
        img=$(dialog --stdout --title "Select Background Image (jpg/png/tga)" --fselect "$start_dir/" "$DIALOG_HEIGHT" "$DIALOG_WIDTH") || return 1
        ;;
      *) return 1 ;;
    esac
    if [[ ! -f "$img" ]]; then
      dialog --title "Background unavailable" --msgbox "Background file not found:\n$img" 8 72
      continue
    fi
    lower="${img,,}"
    if [[ "$lower" != *.jpg && "$lower" != *.jpeg && "$lower" != *.png && "$lower" != *.tga ]]; then
      dialog --title "Invalid file" --msgbox "Select a jpg/png/tga image." 7 40
      continue
    fi

    preview_background_image "$img" || return 1
    if dialog --title "Use this background?" --yesno \
      "Use this Ventoy background?\n\n$(basename -- "$img")" 8 72; then
      SELECTED_BACKGROUND="$img"
      return 0
    fi
    dialog --title "Choose another?" --yesno \
      "Would you like to preview another background?" 7 60 || return 1
  done
}

# Ensure an image-view binary is available; try to download a release asset for current OS/arch
ensure_image_view_available() {
  local bin
  for bin in "$REPO_ROOT/image-view/image-view" "$REPO_ROOT/image-view/bin/image-view"; do
    [[ -x "$bin" ]] && return 0
  done
  mkdir -p "$REPO_ROOT/image-view"
  # Detect OS/arch (linux only)
  local os="linux" arch
  arch=$(uname -m | tr '[:upper:]' '[:lower:]')
  case "$arch" in
    x86_64|amd64) arch_tag="amd64|x86_64" ;;
    aarch64|arm64) arch_tag="arm64|aarch64" ;;
    *) arch_tag="$arch" ;;
  esac
  local api="https://api.github.com/repos/nikolareljin/image-view/releases/latest"
  local tmpdir; tmpdir=$(mktemp -d)
  if curl -fsSL "$api" -o "$tmpdir/latest.json"; then
    local url name
    url=$(jq -r --arg os "$os" --arg arch "$arch_tag" '.assets[] | select((.name|test($os; "i")) and (.name|test($arch; "i"))) | .browser_download_url' "$tmpdir/latest.json" | head -1)
    name=$(jq -r --arg os "$os" --arg arch "$arch_tag" '.assets[] | select((.name|test($os; "i")) and (.name|test($arch; "i"))) | .name' "$tmpdir/latest.json" | head -1)
    if [[ -n "$url" ]]; then
      local dest="$tmpdir/$name"
      if curl -fL "$url" -o "$dest"; then
        if [[ "$name" =~ \.(tar\.gz|tgz)$ ]]; then
          mkdir -p "$tmpdir/extract"
          tar -xzf "$dest" -C "$tmpdir/extract" || true
          local found
          found=$(find "$tmpdir/extract" -type f -perm -111 -iname 'image-view*' | head -1)
          if [[ -n "$found" ]]; then
            cp "$found" "$REPO_ROOT/image-view/image-view" && chmod +x "$REPO_ROOT/image-view/image-view"
          fi
        elif [[ "$name" =~ \.zip$ ]]; then
          command -v unzip >/dev/null 2>&1 && unzip -o "$dest" -d "$tmpdir/extract" || true
          local found
          found=$(find "$tmpdir/extract" -type f -perm -111 -iname 'image-view*' | head -1)
          if [[ -n "$found" ]]; then
            cp "$found" "$REPO_ROOT/image-view/image-view" && chmod +x "$REPO_ROOT/image-view/image-view"
          fi
        else
          cp "$dest" "$REPO_ROOT/image-view/image-view" && chmod +x "$REPO_ROOT/image-view/image-view"
        fi
      fi
    fi
  fi
  rm -rf "$tmpdir"
}

select_iso_creator_base() {
  dialog_init
  load_config
  create_directory "$DOWNLOAD_DIR" >/dev/null || true

  local -a files=() items=()
  mapfile -t files < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -iname '*.iso' -print | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    dialog --title "ISO Creator" --msgbox \
      "No local ISO files found in $DOWNLOAD_DIR. Download a base ISO first." 9 72
    return 1
  fi

  local file
  for file in "${files[@]}"; do
    items+=("$file" "$(basename -- "$file")")
  done
  dialog --stdout --title "ISO Creator — Base ISO" --menu \
    "Choose the local ISO to customize" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}"
}

select_iso_creator_recipe() {
  dialog_init
  local -a recipes=() items=()
  mapfile -t recipes < <(find "$REPO_ROOT/recipes" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)
  if [[ ${#recipes[@]} -eq 0 ]]; then
    dialog --title "ISO Creator" --msgbox "No recipe files found in $REPO_ROOT/recipes." 8 70
    return 1
  fi

  local recipe
  for recipe in "${recipes[@]}"; do
    items+=("$recipe" "$(basename -- "$recipe")")
  done
  dialog --stdout --title "ISO Creator — Recipe" --menu \
    "Choose the customization recipe" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}"
}

iso_creator_output_path() {
  local recipe="$1" output_name
  output_name=$(python3 -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    recipe = yaml.safe_load(stream) or {}
name = (recipe.get("output") or {}).get("name")
if not isinstance(name, str) or not name:
    raise SystemExit(1)
print(name)
' "$recipe" 2>/dev/null) || return 1
  printf '%s/%s.iso\n' "$DOWNLOAD_DIR" "$output_name"
}

create_iso() {
  local base_iso recipe created_iso
  base_iso=$(select_iso_creator_base) || return 1
  recipe=$(select_iso_creator_recipe) || return 1
  created_iso=$(iso_creator_output_path "$recipe") || created_iso="$DOWNLOAD_DIR"

  dialog --title "Create ISO" --yesno \
    "Base ISO:\n  $(basename -- "$base_iso")\n\nRecipe:\n  $(basename -- "$recipe")\n\nThe builder creates a new ISO in $DOWNLOAD_DIR and requires administrator privileges. Continue?" \
    14 76 || return 1

  clear
  local rc
  if (( EUID == 0 )); then
    if "$REPO_ROOT/inc/forge.sh" --recipe "$recipe" --base-iso "$base_iso"; then rc=0; else rc=$?; fi
  else
    if sudo "$REPO_ROOT/inc/forge.sh" --recipe "$recipe" --base-iso "$base_iso"; then rc=0; else rc=$?; fi
  fi

  if (( rc == 0 )); then
    dialog --title "ISO Creator" --msgbox "New ISO created:\n$created_iso" 8 72
  else
    dialog --title "ISO Creator" --msgbox "ISO creation failed (exit $rc). Review the terminal output above for details." 9 72
  fi
  return "$rc"
}

main_menu() {
  # Attempt to install missing dependencies (dialog, jq, curl/wget, util-linux, coreutils)
  ensure_deps
  ensure_dialog
  # Load this in the parent shell. ISO selection uses command substitution, so
  # loading it inside a selector would discard DOWNLOAD_DIR with the subshell.
  load_config
  while true; do
    dialog_init
    local summary; summary=$(show_summary)
    local choice
    choice=$(dialog --stdout --title "$(title)" \
      --menu "${summary}\n\nChoose an action:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 \
      image  "Select ISO files" \
      create "ISO Creator (base ISO + recipe)" \
      bg     "Select Ventoy Background" \
      drive  "Select Drive" \
      flash  "Prepare Ventoy USB" \
      quit   "Quit") || break

    case "$choice" in
      image)  if ! run_main_menu_action select_image_source; then :; fi ;;
      create) if ! create_iso; then :; fi ;;
      bg)     if ! run_main_menu_action select_background_image; then :; fi ;;
      drive) if ! run_main_menu_action select_drive; then :; fi ;;
      flash) if ! run_main_menu_action flash_image; then :; fi ;;
      quit)  break               ;;
    esac
  done
  clear
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse_cli_args "$@"
  if [[ "${ISOFORGE_DISABLE_EXIT_TRAP:-0}" != "1" ]]; then
    trap reset_tui EXIT INT TERM
  fi
  main_menu
fi
