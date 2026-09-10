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
  cat >"$installer" <<EOF
#!/usr/bin/env bash
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
      printf 'sdb1 part 1000000 VENTOY exfat\n'
    fi
  }
  dd() { return 0; }
  # shellcheck disable=SC2317 # invoked indirectly by flash_with_ventoy
  mount() { return 0; }

  SELECTED_DEVICE=sdb
  SELECTED_IMAGES=("$tmpdir/test.iso")
  : >"${SELECTED_IMAGES[0]}"
  flash_with_ventoy
  [[ ! -s "$answer" ]]
  [[ -f "$terminal_notice_seen" ]]
  [[ ! -e "$programbox_seen" ]]
  [[ ! -e "$gauge_seen" ]]

  # Writes to the root-mounted data partition must use the supplied sudo path.
  write_mnt="$tmpdir/write-mnt"
  write_img="$tmpdir/background.png"
  : >"$write_img"
  SELECTED_IMAGES=("$tmpdir/test.iso")
  apply_ventoy_background "$write_mnt" "$write_img" sudo
  copy_isos_to_ventoy "$write_mnt" sudo
  [[ -f "$write_mnt/ventoy/theme/default/background.png" ]]
  [[ -f "$write_mnt/ventoy/theme/default/theme.txt" ]]
  [[ -f "$write_mnt/ventoy/ventoy.json" ]]
  [[ -f "$write_mnt/test.iso" ]]
)

# Bundled backgrounds are PNG because Ventoy renders raster files reliably.
[[ -f "$ROOT_DIR/assets/isoforge-logo.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/isoforge-background.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/nikos-background.svg" ]]
[[ -f "$ROOT_DIR/assets/ventoy/isoforge-background.png" ]]
[[ -f "$ROOT_DIR/assets/ventoy/nikos-background.png" ]]
grep -q 'isoforge "IsoForge — dark forge"' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'nikos "NikOS — dark slate"' "$ROOT_DIR/inc/isoforge.sh"

grep -q 'reports no usable capacity' "$ROOT_DIR/inc/isoforge.sh"
grep -q 'before any validation or Ventoy command' "$ROOT_DIR/inc/isoforge.sh"
