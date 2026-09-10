#!/usr/bin/env bash
# DESCRIPTION: Build a custom installable ISO from a base image and a recipe.
# USAGE: forge --recipe PATH [--base-iso PATH] [--config PATH] [--output DIR] [--work-dir DIR] [--dry-run] [--smoke-test] [--keep] [--version] [--help]
# PARAMETERS:
#   -r, --recipe PATH   Recipe to build. Required.
#       --base-iso PATH Override the recipe base with a local ISO.
#   -o, --output DIR    Where to write the ISO. Defaults to download_dir from config.json.
#       --config PATH   Override the config file the distro catalog is read from.
#       --work-dir DIR  Scratch space for the build. Defaults to /var/tmp/isoforge.
#       --dry-run       Resolve and validate the recipe, then stop. Needs no root.
#       --smoke-test    Boot the finished image under QEMU.
#       --keep          Leave the work directory in place for inspection.
#   -h, --help          Show this help.
#       --version       Print the version.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/scripts/script-helpers" && -f "$SCRIPT_DIR/config.json" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../config.json" && -d "$SCRIPT_DIR/../scripts/script-helpers" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="${ISOFORGE_ROOT:-$SCRIPT_DIR}"
fi
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  >&2 printf "Missing required helper library: %s\n" "$SCRIPT_HELPERS_DIR/helpers.sh"
  >&2 printf "Please install project submodules (e.g. run 'git submodule update --init --recursive') and retry.\n"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging file help

# shellcheck source=/dev/null
source "$REPO_ROOT/inc/download-state.sh"
for module in yaml recipe preflight fetch extract chroot distrodeck customize ansible squashfs image verify; do
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/forge/$module.sh"
done
unset module

CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config.json}"
ISOFORGE_VERSION="${ISOFORGE_VERSION:-$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)}"

RECIPE_PATH=""
OUTPUT_DIR=""
WORK_DIR="${ISOFORGE_WORK_DIR:-/var/tmp/isoforge}"
DRY_RUN=0
SMOKE_TEST=0
KEEP_WORK=0
BASE_ISO_OVERRIDE=""

usage() { display_help; }

parse_args() {
  while (($#)); do
    case "$1" in
      -r|--recipe)   RECIPE_PATH="${2:-}"; shift 2 ;;
      --base-iso)    BASE_ISO_OVERRIDE="${2:-}"; shift 2 ;;
      -o|--output)   OUTPUT_DIR="${2:-}"; shift 2 ;;
      # `isoforge build` forwards its arguments here, and `isoforge` documents
      # --config, so it has to mean the same thing on both sides.
      --config)      CONFIG_FILE="${2:-}"; shift 2 ;;
      --work-dir)    WORK_DIR="${2:-}"; shift 2 ;;
      --dry-run)     DRY_RUN=1; shift ;;
      --smoke-test)  SMOKE_TEST=1; shift ;;
      --keep)        KEEP_WORK=1; shift ;;
      --version)     printf 'isoforge %s\n' "$ISOFORGE_VERSION"; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      *)             log_error "Unknown argument: $1"; usage; exit 2 ;;
    esac
  done

  if [[ -z "$RECIPE_PATH" ]]; then
    log_error "A recipe is required. Try: forge --recipe recipes/example.yml"
    usage
    exit 2
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 2
  fi
  if [[ -n "$BASE_ISO_OVERRIDE" && ! -f "${BASE_ISO_OVERRIDE/#\~/$HOME}" ]]; then
    log_error "Base ISO not found: $BASE_ISO_OVERRIDE"
    exit 2
  fi
}

resolve_output_dir() {
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR=$(jq -r '.download_dir // ""' "$CONFIG_FILE")
    [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$HOME/Downloads/iso_images"
  fi
  OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"

  # Under sudo, $HOME is root's. Writing there would hide the ISO from the user
  # who asked for it, and from the flash flow that reads download_dir.
  if [[ -n "${SUDO_USER:-}" && "$OUTPUT_DIR" == /root/* ]]; then
    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$user_home" ]]; then
      OUTPUT_DIR="${OUTPUT_DIR/#\/root/$user_home}"
    fi
  fi
  mkdir -p "$OUTPUT_DIR"
}

# Runs on every exit path, so a failed build never leaves the host with /proc
# and /sys bound inside the work directory.
forge_teardown() {
  local rc=$?
  set +e
  forge_chroot_leave
  forge_root_teardown "$WORK_DIR/rootfs"
  if ((rc != 0)); then
    log_warn "Build failed. Work directory left at $WORK_DIR for inspection."
  fi
  return $rc
}

main() {
  parse_args "$@"

  local recipe_dir
  recipe_dir="$(cd "$(dirname "$RECIPE_PATH")" && pwd)"

  recipe_load "$RECIPE_PATH" || exit $?

  local name label volume out
  name=$(recipe_get '.output.name')
  label=$(recipe_get '.output.label // ""')
  volume=$(recipe_get '.output.volume_id // ""')
  [[ -n "$volume" ]] || volume="$label"

  resolve_output_dir
  out="$OUTPUT_DIR/${name}.iso"

  log_info "Recipe:  $(recipe_get '.recipe')"
  log_info "Output:  $out"
  log_info "Work:    $WORK_DIR"

  if ((DRY_RUN)); then
    local base_id
    base_id=$(recipe_get '.base.catalog_id // ""')
    if [[ -n "$BASE_ISO_OVERRIDE" ]]; then
      if ! recipe_base_is_compatible "$BASE_ISO_OVERRIDE"; then
        log_error "Base ISO is not compatible with this recipe: $BASE_ISO_OVERRIDE"
        exit 2
      fi
      log_info "Base:    $BASE_ISO_OVERRIDE (local override)"
    elif [[ -n "$base_id" ]]; then
      local url
      url=$(forge_catalog_url "$base_id")
      if [[ -z "$url" ]]; then
        log_error "base.catalog_id '$base_id' is not in $CONFIG_FILE"
        exit 2
      fi
      # The same guard the real build applies to the resolved base below, on
      # the filename this recipe would download. Without it a dry-run reports
      # "Recipe is valid" for a base the build then refuses.
      if ! recipe_base_is_compatible "$url"; then
        log_error "Base ISO is not compatible with this recipe: $(basename -- "$url")"
        exit 2
      fi
      log_info "Base:    $base_id -> $url"
    else
      local configured_base
      configured_base=$(recipe_get '.base.url // .base.iso')
      if ! recipe_base_is_compatible "$configured_base"; then
        log_error "Base ISO is not compatible with this recipe: $(basename -- "$configured_base")"
        exit 2
      fi
      log_info "Base:    $configured_base"
    fi
    log_info "Recipe is valid. Nothing was downloaded or written."
    exit 0
  fi

  if ! forge_require_root; then
    log_error "Building an image needs root: it mounts the base image's filesystems"
    log_error "and chroots into them. Re-run with sudo."
    exit 2
  fi

  forge_preflight "$WORK_DIR" || exit $?

  trap forge_teardown EXIT INT TERM

  mkdir -p "$WORK_DIR"
  local cache_dir="$WORK_DIR/cache"
  local iso_dir="$WORK_DIR/iso"
  local rootfs="$WORK_DIR/rootfs"

  forge_resolve_base "$cache_dir" "$BASE_ISO_OVERRIDE" || exit $?
  if ! recipe_base_is_compatible "$FORGE_BASE_ISO"; then
    log_error "Resolved base ISO is not compatible with this recipe: $FORGE_BASE_ISO"
    exit 2
  fi
  forge_verify_base "$FORGE_BASE_ISO" || exit $?

  forge_extract_iso "$FORGE_BASE_ISO" "$iso_dir" || exit $?
  forge_check_arch "$(forge_detect_arch "$iso_dir" "$FORGE_BASE_ISO")" || exit $?
  forge_detect_layout "$iso_dir" || exit $?
  forge_prepare_root "$WORK_DIR" || exit $?

  if recipe_has '.distrodeck'; then
    local dd_export
    dd_export=$(recipe_get '.distrodeck.export')
    [[ "$dd_export" == /* ]] || dd_export="$recipe_dir/$dd_export"
    local -a dd_sections
    mapfile -t dd_sections < <(recipe_list '.distrodeck.sections')
    forge_dd_load "$dd_export" "${dd_sections[@]}" || exit $?
  fi

  forge_chroot_enter "$rootfs" || exit $?
  forge_customize "$recipe_dir" "$rootfs" || exit $?
  forge_chroot_cleanup

  # The manifest is read out of the chroot, so repack before leaving it.
  forge_repack "$WORK_DIR" "$rootfs" "$iso_dir" || exit $?
  forge_chroot_leave
  forge_root_teardown "$rootfs"

  forge_finalize_tree "$iso_dir" "$volume" "$FORGE_BASE_ISO" || exit $?
  forge_pack "$iso_dir" "$FORGE_BASE_ISO" "$out" "$volume" || exit $?
  forge_verify "$out" || exit $?

  ((SMOKE_TEST)) && forge_smoke_test "$out"

  # The ISO lands in download_dir, so ./isoforge lists it like any other image
  # and the existing flash path writes it to a drive unchanged.
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER" "$out" "$out.sha256" 2>/dev/null || true
  fi

  if ((KEEP_WORK == 0)); then
    # The downloaded base image stays in cache/: it is expensive to fetch and
    # the next build of the same base reuses it.
    log_info "Removing the build scratch directories; the downloaded base image is kept in $WORK_DIR/cache"
    forge_chroot_leave
    rm -rf "${WORK_DIR:?}/rootfs" "${WORK_DIR:?}/iso" "${WORK_DIR:?}/upper" \
           "${WORK_DIR:?}/layers" "${WORK_DIR:?}/overlay-work"
  fi

  log_info "Done. Run ./isoforge to write it to a drive."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
