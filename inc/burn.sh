#!/usr/bin/env bash
# SCRIPT: burn.sh
# DESCRIPTION: Write a selected ISO to a selected drive.
# USAGE: burn [--config PATH] [-h|--help]
# PARAMETERS:
#   --config PATH  Override config file path.
#   -h, --help     Show help and exit.
set -euo pipefail

# Burn a selected ISO to a selected drive, using config.json

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
  1) isoforge_show_help burn; exit 0 ;;
  *) isoforge_show_help burn; exit 2 ;;
esac

# isoforge_parse_config_only_args assigns CONFIG_FILE only when --config was
# given, and everything below the exec is unreachable -- so the default has to
# be here, before the handoff, or `./burn` with no arguments dies on an unbound
# variable under set -u. inc/isoforge.sh does the same, before its own exec.
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config.json}"

# Burning is Ventoy-only. Keep this compatibility entrypoint, but hand off to
# the main workflow instead of writing a raw image with dd.
exec env CONFIG_FILE="$CONFIG_FILE" "$REPO_ROOT/inc/isoforge.sh" "$@"

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  >&2 printf "Missing required helper library: %s\n" "$SCRIPT_HELPERS_DIR/helpers.sh"
  >&2 printf "Please install project submodules (e.g. run 'git submodule update --init --recursive') and retry.\n"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog file os deps

# Always restore a clean terminal UI when exiting (including Cancel/interrupt)
reset_tui() { tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true; clear; }
trap reset_tui EXIT INT TERM


DOWNLOAD_DIR=""
DEVICE_FILTER="usb"
SELECTED_IMAGE=""
SELECTED_DEVICE=""

require_tool() {
  local t="$1"
  if ! command -v "$t" >/dev/null 2>&1; then
    print_error "$t is required but not installed. Run ./setup.sh."
    exit 1
  fi
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi
  require_tool jq
  DOWNLOAD_DIR=$(jq -r '.download_dir // empty' "$CONFIG_FILE")
  [[ -z "$DOWNLOAD_DIR" || "$DOWNLOAD_DIR" == "null" ]] && DOWNLOAD_DIR="$HOME/Downloads/iso_images"
  [[ "$DOWNLOAD_DIR" == ~* ]] && DOWNLOAD_DIR="${DOWNLOAD_DIR/#~/$HOME}"
  DEVICE_FILTER=$(jq -r '.block_device_filter // "usb"' "$CONFIG_FILE")
}

ensure_dialog() {
  check_if_dialog_installed || {
    print_error "Dialog not installed. Run ./setup.sh"
    exit 1
  }
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
  command -v dd >/dev/null 2>&1 || pkgs+=(coreutils)
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    print_info "Installing missing dependencies: ${pkgs[*]}"
    install_dependencies "${pkgs[@]}"
  fi
}

choose_image() {
  dialog_init
  create_directory "$DOWNLOAD_DIR" >/dev/null || true
  mapfile -t files < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -iname "*.iso" 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    local msg="No ISO files found in $DOWNLOAD_DIR.\nRun ./download.sh to fetch images, or browse to a local file."
    dialog --title "No ISOs" --msgbox "$msg" 10 70
    select_local_image || return 1
    return 0
  fi

  # Build menu with numeric tags, showing basenames
  local items=()
  local i=0
  for p in "${files[@]}"; do
    i=$((i+1))
    items+=("$i" "$(basename "$p")")
  done
  items+=("browse" "Browse for another .iso")

  local chosen
  chosen=$(dialog --stdout --title "Select ISO" --menu "Choose an image to burn" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}") || return 1
  if [[ "$chosen" == "browse" ]]; then
    select_local_image || return 1
    return 0
  fi
  local idx=$((chosen-1))
  SELECTED_IMAGE="${files[$idx]}"
}

select_local_image() {
  dialog_init
  local start_dir="${DOWNLOAD_DIR:-$HOME}"
  local iso
  iso=$(dialog --stdout --title "Select ISO" --fselect "$start_dir/" "$DIALOG_HEIGHT" "$DIALOG_WIDTH") || return 1
  [[ -z "$iso" ]] && return 1
  if [[ "${iso,,}" != *.iso ]]; then
    dialog --title "Invalid file" --msgbox "Selected file is not an .iso" 8 50
    return 1
  fi
  SELECTED_IMAGE="$iso"
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
  chosen=$(dialog --stdout --title "Select Drive" --menu "Choose destination drive (data will be destroyed)" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${rows[@]}") || return 1

  # Verify not mounted
  if lsblk "/dev/$chosen" -o MOUNTPOINT -n | grep -q "/"; then
    dialog --title "Drive mounted" --msgbox \
      "Selected drive appears to have mounted partitions.\nPlease unmount all partitions and try again." 9 70
    return 1
  fi
  SELECTED_DEVICE="$chosen"
}

flash_confirm() {
  dialog --stdout --title "Confirm Burn" --yesno \
    "Image:\n  $SELECTED_IMAGE\n\nDrive:\n  /dev/$SELECTED_DEVICE\n\nAll data on the drive will be destroyed. Proceed?" 12 70
}

flash_image() {
  dialog_init
  if [[ -z "${SELECTED_IMAGE:-}" || -z "${SELECTED_DEVICE:-}" ]]; then
    dialog --title "Missing selection" --msgbox "Please select both an image and a drive first." 8 60
    return 1
  fi
  if ! [[ -f "$SELECTED_IMAGE" ]]; then
    dialog --title "Image missing" --msgbox "Selected image not found: $SELECTED_IMAGE" 8 70
    return 1
  fi

  flash_confirm || return 1

  local dev="/dev/$SELECTED_DEVICE"

  # Size of ISO (Linux/macOS)
  local total
  if command -v stat >/dev/null 2>&1; then
    if stat -c %s "$SELECTED_IMAGE" >/dev/null 2>&1; then
      total=$(stat -c %s "$SELECTED_IMAGE")
    else
      total=$(stat -f%z "$SELECTED_IMAGE")
    fi
  else
    total=0
  fi

  local dd_args=(dd if="$SELECTED_IMAGE" of="$dev" bs=4M conv=fsync status=progress)
  local prefix=()
  if command -v sudo >/dev/null 2>&1; then prefix=(sudo); fi

  (
    set +e
    "${prefix[@]}" "${dd_args[@]}" 2>&1 |
      awk -v total="$total" '
        /^[0-9]+ bytes/ {
          cur=$1; pct=(total>0)?int(cur*100/total):0; if (pct>100)pct=100;
          print "XXX"; print pct; printf("Writing... %s bytes\n", cur); print "XXX"; fflush();
        }
      END { print "XXX"; print 100; print "Finalizing..."; print "XXX"; fflush(); }'
    status=$?
    echo "$status" >"$REPO_ROOT/.burn_status.tmp"
  ) | dialog --title "Burning to $dev" --gauge "Starting..." 12 "$DIALOG_WIDTH" 0

  local status; status=$(cat "$REPO_ROOT/.burn_status.tmp" 2>/dev/null || echo 1)
  rm -f "$REPO_ROOT/.burn_status.tmp"
  sync || true

  if [[ "$status" -eq 0 ]]; then
    dialog --title "Success" --msgbox "Burn completed successfully." 7 40
  else
    dialog --title "Error" --msgbox "Burn failed. Check permissions and device." 8 60
    return 1
  fi
}

main() {
  ensure_deps
  ensure_dialog
  load_config
  choose_image || exit 1
  select_drive || exit 1
  flash_image
}

main "$@"
