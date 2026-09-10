#!/usr/bin/env bash
# Regression coverage for Ventoy selection and compressed catalog images.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(
  cd "$ROOT_DIR"
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  source ./inc/isoforge.sh
  DIALOG_HEIGHT=20
  DIALOG_WIDTH=72

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  download_dir="$tmpdir/images"
  mkdir -p "$download_dir"
  spaced_iso="$download_dir/My ISO.iso"
  : >"$spaced_iso"
  archive="$download_dir/appliance.img.gz"
  printf 'raw image payload' | gzip -c >"$archive"
  cat >"$tmpdir/config.json" <<EOF
{"download_dir":"$download_dir","distros":[]}
EOF
  CONFIG_FILE="$tmpdir/config.json"

  dialog_init() { :; }
  dialog() {
    if [[ "$*" == *--checklist* ]]; then
      printf '%s\n%s\n' "$spaced_iso" "$archive"
    fi
  }
  select_images_local_multi
  [[ ${#SELECTED_IMAGES[@]} -eq 2 ]]
  [[ "${SELECTED_IMAGES[0]}" == "$spaced_iso" ]]
  normalized="$download_dir/appliance.img"
  [[ "${SELECTED_IMAGES[1]}" == "$normalized" ]]
  [[ "$normalized" == "$download_dir/appliance.img" ]]
  [[ "$(cat "$normalized")" == 'raw image payload' ]]
  [[ "$(normalize_ventoy_image "$normalized")" == "$normalized" ]]

  ISOFORGE_CACHE_DIR="$tmpdir/cache"
  [[ "$(ventoy_cache_dir)" == "$tmpdir/cache/ventoy" ]]

  [[ "$SELECTED_BACKGROUND" == "$REPO_ROOT/assets/ventoy/isoforge-background.png" ]]
)

# Both compatibility entrypoints preserve an explicit config when they enter
# the Ventoy TUI; config before the subcommand is carried through the environment.
grep -Fq 'exec env CONFIG_FILE="$CONFIG_FILE" "$REPO_ROOT/inc/isoforge.sh" "$@"' "$ROOT_DIR/inc/burn.sh"
grep -Fq 'exec env CONFIG_FILE="$CONFIG_FILE" "$REPO_ROOT/inc/isoforge.sh" "$@"' "$ROOT_DIR/inc/isoforge.sh"
grep -Fq 'dialog --stdout --separate-output' "$ROOT_DIR/inc/isoforge.sh"
grep -Fq '"$cache_dir"/ventoy-*/Ventoy2Disk.sh' "$ROOT_DIR/inc/isoforge.sh"
grep -Fq 'tar -xzf "$tmpdir/ventoy.tgz" -C "$cache_dir"' "$ROOT_DIR/inc/isoforge.sh"
grep -Fq '! -s "$efi_mount/EFI/BOOT/BOOTX64.EFI"' "$ROOT_DIR/inc/isoforge.sh"
grep -Fq 'xz-utils gzip bzip2' "$ROOT_DIR/inc/cli-help.sh"
