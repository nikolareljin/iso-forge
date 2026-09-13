#!/usr/bin/env bash
# Unpacking the base image and presenting its root filesystem for editing.
#
# Ubuntu ships two casper layouts and they need different treatment:
#
#   single   one casper/filesystem.squashfs holding the whole root. Unpack it,
#            edit the directory, squash the directory back. This is what the
#            flavours using Ubiquity ship.
#
#   layered  casper/minimal.squashfs, then minimal.standard.squashfs and
#            minimal.standard.live.squashfs stacked on top of it, listed in
#            casper/install-sources.yaml. Rewriting one of those in place would
#            mean deciding which files belong to which layer. Instead the layers
#            are loop-mounted read-only as overlayfs lowerdirs and the build
#            writes into a fresh upperdir, so the customization is captured
#            exactly as its own new top layer.

FORGE_LAYOUT=""
FORGE_TOP_LAYER=""          # squashfs the new content layers on top of
FORGE_LAYER_PATHS=()        # every layer, lowest first
FORGE_LAYER_MOUNTS=()       # loop mounts to release, in reverse
FORGE_ROOT_MOUNTED=0

forge_extract_iso() {
  local iso="$1" dest="$2"

  log_info "Extracting $(basename "$iso")"
  rm -rf "$dest"
  mkdir -p "$dest"

  # -osirrox reads the image without a loop mount, so this stage needs no
  # privileges and cannot leave a mount behind if it fails.
  if ! xorriso -osirrox on -indev "$iso" -extract / "$dest" >/dev/null 2>&1; then
    log_error "Could not extract $iso"
    return 1
  fi

  # The extracted tree comes out read-only, matching the image.
  chmod -R u+w "$dest"
}

forge_detect_layout() {
  local iso_dir="$1"
  local casper="$iso_dir/casper"

  FORGE_LAYER_PATHS=()
  FORGE_TOP_LAYER=""

  if [[ -f "$iso_dir/antiX/linuxfs" ]]; then
    FORGE_LAYOUT="antix"
    FORGE_LAYER_PATHS=("$iso_dir/antiX/linuxfs")
    FORGE_TOP_LAYER="$iso_dir/antiX/linuxfs"
    log_info "Layout: antiX live filesystem (antiX/linuxfs)"
    return 0
  fi

  if [[ ! -d "$casper" ]]; then
    log_error "No casper/ directory in the base image."
    log_error "isoforge remasters Debian-family live images (Ubuntu, Xubuntu, Debian live)."
    log_error "Found at the top level: $(ls -1 "$iso_dir" | paste -sd' ' -)"
    return 2
  fi

  if [[ -f "$casper/filesystem.squashfs" ]]; then
    FORGE_LAYOUT="single"
    FORGE_LAYER_PATHS=("$casper/filesystem.squashfs")
    FORGE_TOP_LAYER="$casper/filesystem.squashfs"
    log_info "Layout: single squashfs (casper/filesystem.squashfs)"
    return 0
  fi

  # Layer order matters and is not alphabetical in general, but Ubuntu's names
  # nest by prefix, so sorting by path length puts the base first and each
  # successive layer after the one it extends.
  local found=()
  mapfile -t found < <(find "$casper" -maxdepth 1 -name '*.squashfs' -printf '%f\n' | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-)

  if ((${#found[@]} == 0)); then
    log_error "No .squashfs found in $casper"
    return 2
  fi

  local f
  for f in "${found[@]}"; do
    FORGE_LAYER_PATHS+=("$casper/$f")
  done
  FORGE_LAYOUT="layered"
  FORGE_TOP_LAYER="${FORGE_LAYER_PATHS[-1]}"
  log_info "Layout: layered squashfs, ${#FORGE_LAYER_PATHS[@]} layer(s): $(printf '%s ' "${found[@]}")"

  # The topmost squashfs is not necessarily the one the installer lays down.
  # Ubuntu ships minimal.standard.live above minimal.standard, and only the
  # latter is installed; the live layer exists for the session you boot into.
  # Building on top of the live layer would put the customization somewhere the
  # installer never reads, so follow install-sources.yaml instead and drop any
  # layer stacked above the one it names.
  local sources="$iso_dir/casper/install-sources.yaml"
  local stem
  if stem=$(forge_yaml_install_source_stem "$sources" 2>/dev/null) && [[ -n "$stem" ]]; then
    if [[ -f "$casper/${stem}.squashfs" ]]; then
      local kept=() p
      for p in "${FORGE_LAYER_PATHS[@]}"; do
        kept+=("$p")
        [[ "$(basename "$p" .squashfs)" == "$stem" ]] && break
      done
      FORGE_LAYER_PATHS=("${kept[@]}")
      FORGE_TOP_LAYER="$casper/${stem}.squashfs"
      log_info "The installer uses '${stem}'; building on that, over ${#FORGE_LAYER_PATHS[@]} layer(s)"
    else
      log_warn "install-sources.yaml names '${stem}', which has no squashfs; using the topmost layer."
    fi
  fi
  return 0
}

forge_root_teardown() {
  local rootfs="$1"

  if ((FORGE_ROOT_MOUNTED)); then
    umount "$rootfs" 2>/dev/null || umount -l "$rootfs" 2>/dev/null || true
    FORGE_ROOT_MOUNTED=0
  fi

  local i
  for ((i = ${#FORGE_LAYER_MOUNTS[@]} - 1; i >= 0; i--)); do
    umount "${FORGE_LAYER_MOUNTS[i]}" 2>/dev/null || umount -l "${FORGE_LAYER_MOUNTS[i]}" 2>/dev/null || true
  done
  FORGE_LAYER_MOUNTS=()
}

# After this returns, $work/rootfs is a writable view of the base system that
# the chroot stage can enter, whichever layout the image uses.
forge_prepare_root() {
  local work="$1"
  local rootfs="$work/rootfs"

  case "$FORGE_LAYOUT" in
    single|antix)
      log_info "Unpacking root filesystem (this takes a few minutes)"
      rm -rf "$rootfs"
      if ! unsquashfs -d "$rootfs" "$FORGE_TOP_LAYER" >/dev/null; then
        log_error "unsquashfs failed on $FORGE_TOP_LAYER"
        return 1
      fi
      ;;
    layered)
      local lower_dir="$work/layers" upper="$work/upper" workdir="$work/overlay-work"
      rm -rf "$lower_dir" "$upper" "$workdir" "$rootfs"
      mkdir -p "$lower_dir" "$upper" "$workdir" "$rootfs"

      local lowers=() i=0 mnt
      for path in "${FORGE_LAYER_PATHS[@]}"; do
        mnt="$lower_dir/$i"
        mkdir -p "$mnt"
        if ! mount -t squashfs -o ro,loop "$path" "$mnt"; then
          log_error "Could not mount layer $path"
          return 1
        fi
        FORGE_LAYER_MOUNTS+=("$mnt")
        lowers+=("$mnt")
        i=$((i + 1))
      done

      # overlayfs reads lowerdir highest-priority first, the reverse of the
      # order the layers stack in.
      local joined="" j
      for ((j = ${#lowers[@]} - 1; j >= 0; j--)); do
        joined+="${lowers[j]}"
        ((j > 0)) && joined+=":"
      done

      log_info "Stacking ${#lowers[@]} layers; the build writes to a new top layer"
      if ! mount -t overlay overlay -o "lowerdir=$joined,upperdir=$upper,workdir=$workdir" "$rootfs"; then
        log_error "Could not mount the overlay. Does this kernel have overlayfs?"
        return 1
      fi
      FORGE_ROOT_MOUNTED=1
      ;;
    *)
      log_error "Unknown layout '$FORGE_LAYOUT'"
      return 2
      ;;
  esac
}
