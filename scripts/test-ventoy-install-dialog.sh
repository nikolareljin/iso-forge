#!/usr/bin/env bash
# Ensure Ventoy's text output and confirmation are handled by dialog safely.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(
  cd "$ROOT_DIR"
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  source ./inc/isoforge.sh
  DIALOG_WIDTH=72

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  installer="$tmpdir/Ventoy2Disk.sh"
  answer="$tmpdir/answer"
  installer_args="$tmpdir/installer-args"
  cat >"$installer" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$installer_args"
if read -r reply; then
  printf '%s' "\$reply" >"$answer"
else
  : >"$answer"
fi
printf 'Ventoy text output remains in the terminal\n'
EOF
  chmod +x "$installer"

  programbox_seen="$tmpdir/programbox-seen"
  gauge_seen="$tmpdir/gauge-seen"
  terminal_notice_seen="$tmpdir/terminal-notice-seen"
  REPO_ROOT="$tmpdir"
  # shellcheck disable=SC2317 # invoked indirectly by flash_with_ventoy
  dialog_init() { :; }
  dialog() {
    [[ "$*" == *--programbox* ]] && : >"$programbox_seen"
    [[ "$*" == *--gauge* ]] && : >"$gauge_seen"
    [[ "$*" == *'Ventoy will now continue in the terminal'* ]] && : >"$terminal_notice_seen"
    return 0
  }
  sudo() {
    [[ "${1:-}" == '-v' ]] && return 0
    "$@"
  }
  ensure_ventoy_available() { VENTOY_BIN="$installer"; }
  flash_confirm() { return 0; }
  ensure_space_or_prune() { return 0; }
  sync() { :; }
  lsblk() {
    if [[ "$*" == *'-dn'* && "$*" == *SIZE* ]]; then
      printf '1000000\n'
    elif [[ "$*" == *'-ln'* ]]; then
      printf 'sdb1 part 1000000 Ventoy exfat\nsdb2 part 32000000 VTOYEFI vfat\n'
    fi
  }
  dd() { return 0; }
  # shellcheck disable=SC2317 # invoked indirectly by flash_with_ventoy
  mount() {
    local target="${!#}"
    mkdir -p "$target/EFI/BOOT"
    printf 'efi loader' >"$target/EFI/BOOT/BOOTX64.EFI"
  }
  umount() { return 0; }
  sleep() { :; }

  SELECTED_DEVICE=sdb
  SELECTED_IMAGES=("$tmpdir/test.iso")
  : >"${SELECTED_IMAGES[0]}"
  flash_with_ventoy
  [[ ! -s "$answer" ]]
  [[ -f "$terminal_notice_seen" ]]
  [[ ! -e "$programbox_seen" ]]
  [[ ! -e "$gauge_seen" ]]
  [[ "$(cat "$installer_args")" == "-I /dev/sdb" ]]

  # Writes to the root-mounted data partition must use the supplied sudo path.
  write_mnt="$tmpdir/write-mnt"
  write_img="$tmpdir/background.png"
  : >"$write_img"
  SELECTED_IMAGES=("$tmpdir/test.iso")
  apply_ventoy_background "$write_mnt" "$write_img" sudo
  copy_isos_to_ventoy "$write_mnt" sudo
  [[ -f "$write_mnt/ventoy/theme/default/background.png" ]]
  [[ -f "$write_mnt/ventoy/theme/default/theme.txt" ]]
  grep -q 'top = 32%' "$write_mnt/ventoy/theme/default/theme.txt"
  grep -q 'height = 56%' "$write_mnt/ventoy/theme/default/theme.txt"
  [[ -f "$write_mnt/ventoy/ventoy.json" ]]
  grep -q '"gfxmode": "max"' "$write_mnt/ventoy/ventoy.json"
  [[ -f "$write_mnt/test.iso" ]]
)

# Bundled backgrounds are PNG because Ventoy renders raster files reliably.
[[ -f "$ROOT_DIR/assets/isoforge-logo.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/isoforge-background.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/nikos-background.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/isoforge-background.png" ]]
[[ -f "$ROOT_DIR/assets/ventoy/nikos-background.png" ]]
grep -q 'SELECTED_BACKGROUND="$REPO_ROOT/assets/ventoy/isoforge-background.png"' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'isoforge "IsoForge — dark forge (default)"' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'nikos "NikOS — dark slate"' "$ROOT_DIR/inc/isoforge.sh"

grep -q 'reports no usable capacity' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'before any validation or Ventoy command' "$ROOT_DIR/inc/isoforge.sh"
grep -q '"$VENTOY_BIN" -I "$dev"' "$ROOT_DIR/inc/isoforge.sh"
! grep -q '"$VENTOY_BIN" -I -g "$dev"' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'verify_ventoy_efi_bootloader' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'cleanup_ventoy_data_mount' "$ROOT_DIR/inc/isoforge.sh"

grep -q '"$viewer" -g "$img"' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'Use this Ventoy background?' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'Would you like to preview another background?' "$ROOT_DIR/inc/isoforge.sh"
