#!/usr/bin/env bash
# Writing the customized root filesystem back into the image tree.

FORGE_SQUASHFS_COMP="${FORGE_SQUASHFS_COMP:-zstd}"
FORGE_SQUASHFS_LEVEL="${FORGE_SQUASHFS_LEVEL:-19}"

forge_mksquashfs() {
  local src="$1" dest="$2"
  local -a args=(-noappend -b 1M -comp "$FORGE_SQUASHFS_COMP" -wildcards -e 'boot/grub')

  # -Xcompression-level is only meaningful for the algorithms that take one.
  case "$FORGE_SQUASHFS_COMP" in
    zstd|xz) args+=(-Xcompression-level "$FORGE_SQUASHFS_LEVEL") ;;
  esac

  rm -f "$dest"
  log_info "Compressing the root filesystem with $FORGE_SQUASHFS_COMP (this is the slow part)"
  if ! mksquashfs "$src" "$dest" "${args[@]}" >/dev/null; then
    log_error "mksquashfs failed writing $dest"
    return 1
  fi
}

# casper reads filesystem.size to size its progress bar, and the installer
# reads the manifest to decide what to remove for a minimal install. Both are
# stale the moment packages change.
forge_write_manifest() {
  local rootfs="$1" casper="$2" stem="$3"

  local size
  size=$(du -sx --block-size=1 "$rootfs" | cut -f1)
  printf '%s' "$size" >"$casper/${stem}.size"

  if [[ -f "$casper/${stem}.manifest" ]] || [[ -f "$casper/filesystem.manifest" ]]; then
    log_info "Regenerating the package manifest"
    # Through a temporary file: a redirection straight onto the manifest
    # truncates it before dpkg-query runs, so a failure would leave an empty
    # one behind and "leaving the previous one" would be a lie.
    local tmp="$casper/${stem}.manifest.isoforge-new"
    if forge_in_chroot "dpkg-query -W --showformat='\${Package} \${Version}\n'" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$casper/${stem}.manifest"
    else
      rm -f "$tmp"
      log_warn "Could not regenerate ${stem}.manifest; leaving the previous one."
    fi
  fi
}

forge_repack_single() {
  local rootfs="$1" iso_dir="$2"
  local casper="$iso_dir/casper"

  forge_write_manifest "$rootfs" "$casper" "filesystem"
  forge_mksquashfs "$rootfs" "$casper/filesystem.squashfs" || return $?
}

# The overlay upperdir holds exactly what the build changed, including
# overlayfs whiteouts for deletions, which mksquashfs preserves as the
# character devices casper's overlay understands.
forge_repack_antix() {
  local rootfs="$1" iso_dir="$2" payload="$iso_dir/antiX/linuxfs"
  forge_mksquashfs "$rootfs" "$payload" || return $?
  ( cd "$iso_dir/antiX" && md5sum linuxfs > linuxfs.md5 ) || return 1
}

forge_repack_layered() {
  local work="$1" iso_dir="$2"
  local casper="$iso_dir/casper"
  local upper="$work/upper"
  local stem name

  stem="$(basename "$FORGE_TOP_LAYER" .squashfs)"
  name="${stem}.isoforge"

  if [[ -z "$(ls -A "$upper" 2>/dev/null)" ]]; then
    log_warn "The build changed nothing; not adding an empty layer."
    return 0
  fi

  log_info "Writing the customization as a new layer: ${name}.squashfs"
  forge_mksquashfs "$upper" "$casper/${name}.squashfs" || return $?

  local size
  size=$(du -sx --block-size=1 "$upper" | cut -f1)
  printf '%s' "$size" >"$casper/${name}.size"

  forge_carry_sidecars "$casper" "$stem" "$name" || return $?
  forge_register_layer "$iso_dir" "$name" || return $?
}

# install-sources.yaml names a layer by stem, and the installer looks for that
# stem's sidecar files too. The manifest in particular decides what a minimal
# install removes, so a repointed layer with no manifest, or with the base
# layer's stale one, gets minimal installs wrong.
forge_carry_sidecars() {
  local casper="$1" stem="$2" name="$3"

  # The manifest describes the whole stack as it now stands, so it is read from
  # the merged view rather than copied. This runs while the chroot is still up.
  local tmp="$casper/${name}.manifest.isoforge-new"
  if forge_in_chroot "dpkg-query -W --showformat='\${Package} \${Version}\n'" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$casper/${name}.manifest"
    log_info "Wrote ${name}.manifest from the finished system"
  else
    rm -f "$tmp"
    if [[ -f "$casper/${stem}.manifest" ]]; then
      log_warn "Could not read the package list; carrying ${stem}.manifest over unchanged."
      cp -a "$casper/${stem}.manifest" "$casper/${name}.manifest"
    else
      log_warn "No package manifest for ${name}; a minimal install may keep packages it would otherwise remove."
    fi
  fi

  # The remove lists say which packages a minimal install strips. They describe
  # the vendor's own selection, so they are carried over as they are.
  local suffix src
  for suffix in manifest-remove manifest-minimal-remove size-minimal; do
    src="$casper/${stem}.${suffix}"
    [[ -f "$src" ]] || continue
    cp -a "$src" "$casper/${name}.${suffix}"
  done
}

# install-sources.yaml is what the installer reads to find the filesystem it
# should lay down. A new layer that is not registered there is carried on the
# ISO and ignored.
forge_register_layer() {
  local iso_dir="$1" name="$2"
  local sources="$iso_dir/casper/install-sources.yaml"

  # Without this file the installer has no way to be told about the new layer,
  # so the image would install the base system and silently drop everything the
  # build added. That is worse than not producing an image.
  if [[ ! -f "$sources" ]]; then
    log_error "This image has layered squashfs but no casper/install-sources.yaml,"
    log_error "so ${name}.squashfs cannot be registered and would be ignored by the installer."
    return 1
  fi

  log_info "Registering the new layer in install-sources.yaml"
  local from
  from="$(basename "$FORGE_TOP_LAYER" .squashfs)"
  cp -a "$sources" "$sources.isoforge-orig"
  if ! forge_yaml_repoint_source "$sources" "$from" "$name"; then
    # Leave the original in place rather than writing something the installer
    # might choke on, and say exactly what needs doing by hand.
    mv -f "$sources.isoforge-orig" "$sources"
    log_error "Could not repoint install-sources.yaml from '$from' to '$name'."
    log_error "The installer would keep using '$from' and ignore everything this"
    log_error "build added, so the image is not written. Edit the file by hand and"
    log_error "re-run, or report the layout it uses."
    return 1
  fi
  rm -f "$sources.isoforge-orig"
}

forge_repack() {
  local work="$1" rootfs="$2" iso_dir="$3"

  case "$FORGE_LAYOUT" in
    single)  forge_repack_single "$rootfs" "$iso_dir" ;;
    antix)   forge_repack_antix "$rootfs" "$iso_dir" ;;
    layered) forge_repack_layered "$work" "$iso_dir" ;;
    *)       log_error "Unknown layout '$FORGE_LAYOUT'"; return 2 ;;
  esac
}
