#!/usr/bin/env bash
# SCRIPT: download.sh
# DESCRIPTION: Download one or more ISOs from the configured distro catalog.
# USAGE: download [--config PATH] [-h|--help]
# PARAMETERS:
#   --config PATH  Override config file path.
#   -h, --help     Show help and exit.
set -euo pipefail

# Load shared helpers from submodule in ./scripts (override with SCRIPT_HELPERS_DIR)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve repo root so script works whether run via root-level symlink or directly
if [[ -d "$SCRIPT_DIR/scripts/script-helpers" && -f "$SCRIPT_DIR/config.json" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../config.json" && -d "$SCRIPT_DIR/../scripts/script-helpers" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="$SCRIPT_DIR"
fi
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
if [[ -f "$REPO_ROOT/inc/cli-help.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/cli-help.sh"
else
  >&2 printf "Missing required CLI help file: %s\n" "$REPO_ROOT/inc/cli-help.sh"
  exit 1
fi

set +e
isoforge_parse_config_only_args "$@"
parse_status=$?
set -e
case "$parse_status" in
  0) ;;
  1) isoforge_show_help download; exit 0 ;;
  *) isoforge_show_help download; exit 2 ;;
esac

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  >&2 printf "Missing required helper library: %s\n" "$SCRIPT_HELPERS_DIR/helpers.sh"
  >&2 printf "Please install project submodules (e.g. run 'git submodule update --init --recursive') and retry.\n"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog file os deps
if [[ -f "$REPO_ROOT/inc/download-state.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/download-state.sh"
else
  >&2 printf "Missing required state file: %s\n" "$REPO_ROOT/inc/download-state.sh"
  >&2 printf "This script appears to be running from a partial or incomplete installation.\n"
  exit 1
fi

# Always restore a clean terminal UI when exiting (including Cancel/interrupt)
reset_tui() { tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true; clear; }
trap reset_tui EXIT INT TERM

CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config.json}"

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

show_http_override_warning_once() {
  if [[ -n "${HTTP_DOWNLOAD_WARNING_SHOWN:-}" ]]; then
    return 0
  fi
  HTTP_DOWNLOAD_WARNING_SHOWN=1
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "Insecure HTTP Override Enabled" --msgbox \
      "ALLOW_INSECURE_HTTP_DOWNLOADS=1 is set.\nThis allows insecure HTTP downloads and is not recommended." 8 72
  else
    >&2 printf "Warning: ALLOW_INSECURE_HTTP_DOWNLOADS=1 set; using insecure HTTP download URL(s).\n"
  fi
}

is_allowed_download_url() {
  local url="$1"
  if [[ "$url" == https://* ]]; then
    return 0
  fi
  if [[ "$url" == http://* ]]; then
    if ! is_http_override_enabled; then
      return 1
    fi
    show_http_override_warning_once
    return 0
  fi
  return 1
}

# Resolve download dir and read distros from config.json
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi
  require_tool jq

  DOWNLOAD_DIR=$(jq -r '.download_dir // empty' "$CONFIG_FILE")
  if [[ -z "$DOWNLOAD_DIR" || "$DOWNLOAD_DIR" == "null" ]]; then
    DOWNLOAD_DIR="$HOME/Downloads/iso_images"
  fi
  # Expand ~ if used
  [[ "$DOWNLOAD_DIR" == ~* ]] && DOWNLOAD_DIR="${DOWNLOAD_DIR/#~/$HOME}"
}

# Install required tools if missing using script-helpers
ensure_deps() {
  local pkgs=()
  command -v dialog >/dev/null 2>&1 || pkgs+=(dialog)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    pkgs+=(curl wget)
  fi
  command -v lsblk >/dev/null 2>&1 || pkgs+=(util-linux)
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    print_info "Installing missing dependencies: ${pkgs[*]}"
    install_dependencies "${pkgs[@]}"
  fi
}

ensure_deps
check_if_dialog_installed
dialog_init
load_config
create_directory "$DOWNLOAD_DIR" >/dev/null || true

############################################################
# Build grouped checklist (consistent order + visual headers)
############################################################

# Return category for an id/label pair
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

declare -A DISTROS
declare -A URLS
declare -A BROWSER_URLS
mapfile -t rows < <(jq -r '.distros[] | "\(.id)\t\(.label)\t\(.url // \"\")\t\(.browser_url // \"\")"' "$CONFIG_FILE")
if [[ ${#rows[@]} -eq 0 ]]; then
  print_error "No distros defined in config.json"
  exit 1
fi

items=()
prev_cat=""
for line in "${rows[@]}"; do
  id="${line%%$'\t'*}"; rest="${line#*$'\t'}"; label="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; url="${rest%%$'\t'*}"; browser_url="${rest#*$'\t'}"
  DISTROS["$id"]="$label"
  URLS["$id"]="$url"
  BROWSER_URLS["$id"]="$browser_url"
  cat=$(distro_category "$id" "$label")
  if [[ "$cat" != "$prev_cat" ]]; then
    items+=("hdr_${cat// /_}" "==== $cat ====" off)
    prev_cat="$cat"
  fi
  items+=("$id" "$label" off)
done

selected=$(dialog --stdout --title "Download ISOs" --checklist "Select one or more distros to download" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || {
  print_warning "No selection made. Exiting."
  exit 1
}

# dialog returns space-separated quoted ids, e.g., "Ubuntu_24" "Fedora_40"
selected=$(sed 's/\"//g' <<<"$selected")

pushd "$DOWNLOAD_DIR" >/dev/null
clear_last_download_error
errors=0
handoffs=0
downloads=0
for id in $selected; do
  # Skip category headers if user selected them
  if [[ "$id" == hdr_* ]]; then continue; fi
  url="${URLS[$id]:-}"
  browser_url="${BROWSER_URLS[$id]:-}"
  if [[ -n "$browser_url" ]]; then
    if ! is_browser_url "$browser_url"; then
      print_error "Skipping $id due to unsupported browser URL: $browser_url"
      errors=$((errors+1))
    elif open_browser_url "$browser_url"; then
      print_info "Opened $id in your browser. Complete the authenticated download there."
      handoffs=$((handoffs+1))
    else
      print_error "Could not open a browser for $id. Open this URL manually: $browser_url"
      errors=$((errors+1))
    fi
    continue
  fi
  if [[ -z "$url" || "$url" == "null" ]]; then
    print_error "No URL for $id in config.json"; errors=$((errors+1)); continue
  fi
  if ! is_allowed_download_url "$url"; then
    if [[ "$url" == http://* ]]; then
      print_error "Skipping $id due to insecure HTTP URL (set ALLOW_INSECURE_HTTP_DOWNLOADS=1 to override): $url"
    else
      print_error "Skipping $id due to unsupported URL scheme (http/https required): $url"
    fi
    errors=$((errors+1))
    continue
  fi
  output=$(derive_download_output_name "$url")
  if ! download_file_with_error_tracking "$url" "$output" "batch-download" "$id"; then
    print_error "Failed to download $id"
    errors=$((errors+1))
  else
    downloads=$((downloads+1))
  fi
done
popd >/dev/null

if [[ "$errors" -eq 0 ]]; then
  # A browser handoff downloads nothing here: saying "files saved to ..." after
  # a batch that only opened browser tabs names a directory that gained no file.
  if (( downloads > 0 )); then
    print_success "Download completed! Files saved to $DOWNLOAD_DIR"
    if (( handoffs > 0 )); then
      print_info "$handoffs selection(s) opened in your browser; finish those downloads there."
    fi
  elif (( handoffs > 0 )); then
    print_success "Opened $handoffs selection(s) in your browser. Nothing was downloaded here; complete them there and save to $DOWNLOAD_DIR."
  else
    print_info "Nothing to download."
  fi
else
  print_warning "Completed with $errors error(s). Check logs."
  if has_last_download_error; then
    print_last_download_error_cli
  fi
fi

# End of script
