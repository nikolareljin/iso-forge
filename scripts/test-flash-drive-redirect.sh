#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$ROOT_DIR"
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  source ./inc/isoforge.sh

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  iso_path="$tmpdir/test.iso"
  : >"$iso_path"

  drive_warning_seen=0
  select_drive_called=0
  ventoy_called=0

  dialog_init() { :; }
  dialog() {
    if [[ "$*" == *"Please select a drive first."* ]]; then
      drive_warning_seen=1
    fi
    return 0
  }
  select_drive() {
    select_drive_called=1
    SELECTED_DEVICE="sdb"
    return 0
  }
  flash_with_ventoy() {
    ventoy_called=1
    return 1
  }

  SELECTED_IMAGE="$iso_path"
  SELECTED_IMAGES=("$iso_path")
  SELECTED_DEVICE=""

  set +e
  run_main_menu_action flash_image
  status=$?
  set -e

  [[ "$status" -eq 1 ]]
  [[ "$drive_warning_seen" -eq 1 ]]
  [[ "$select_drive_called" -eq 1 ]]
  [[ "$ventoy_called" -eq 1 ]]
  [[ "$SELECTED_IMAGE" == "$iso_path" ]]
  [[ -z "${SELECTED_DEVICE:-}" ]]
)
