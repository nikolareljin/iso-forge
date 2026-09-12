#!/usr/bin/env bash
# Layout detection, squashfs repacking and ISO packing, against a synthetic
# image a few hundred kilobytes in size.
#
# This exercises the real code on a real ISO rather than a mock: a full Ubuntu
# base is several gigabytes and needs root to chroot into, neither of which
# belongs in a pull-request check. The stages that need root (bind mounts,
# chroot, overlayfs) are skipped here and are covered by the documented manual
# build in docs/BUILD.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  echo "script-helpers not initialized; run ./update" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging file
for m in yaml recipe preflight fetch extract chroot squashfs image verify; do
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/forge/$m.sh"
done

pass=0
fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

for t in xorriso mksquashfs unsquashfs; do
  if ! command -v "$t" >/dev/null 2>&1; then
    printf 'SKIP - %s is not installed; image tests need xorriso and squashfs-tools\n' "$t"
    exit 0
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- build a synthetic base image ------------------------------------------
make_base() {
  local layout="$1"
  local root="$TMP/$layout"
  rm -rf "$root"
  mkdir -p "$root/tree/.disk" "$root/rootfs/etc" "$root/rootfs/usr/bin"

  printf 'synthetic\n' >"$root/rootfs/etc/os-release"
  printf 'placeholder\n' >"$root/rootfs/usr/bin/true-ish"
  printf 'Synthetic 24.04 release amd64\n' >"$root/tree/.disk/info"
  printf 'nothing here\n' >"$root/tree/README.diskdefines"

  case "$layout" in
    single)
      mkdir -p "$root/tree/casper"
      mksquashfs "$root/rootfs" "$root/tree/casper/filesystem.squashfs" -noappend -quiet >/dev/null
      ;;
    antix)
      mkdir -p "$root/tree/antiX"
      mksquashfs "$root/rootfs" "$root/tree/antiX/linuxfs" -noappend -quiet >/dev/null
      ( cd "$root/tree/antiX" && md5sum linuxfs > linuxfs.md5 )
      ;;
    layered)
      mkdir -p "$root/tree/casper"
      mkdir -p "$root/lower2"
      printf 'standard layer\n' >"$root/lower2/marker"
      mksquashfs "$root/rootfs" "$root/tree/casper/minimal.squashfs" -noappend -quiet >/dev/null
      mksquashfs "$root/lower2" "$root/tree/casper/minimal.standard.squashfs" -noappend -quiet >/dev/null
      # Three layers like a real Ubuntu image, where the installer uses
      # minimal.standard and minimal.standard.live exists only for the live
      # session and sits above it.
      mkdir -p "$root/lower3"
      printf 'live layer\n' >"$root/lower3/live-marker"
      mksquashfs "$root/lower3" "$root/tree/casper/minimal.standard.live.squashfs" -noappend -quiet >/dev/null
      cat >"$root/tree/casper/install-sources.yaml" <<'YAML'
- default: false
  description:
    en: A minimal installation.
  id: synthetic-minimal
  locale_support: langpack
  name:
    en: Synthetic Minimal
  path: minimal.squashfs
  size: 1024
  type: fsimage-layered
  variant: desktop
- default: true
  description:
    en: A full featured installation.
  id: synthetic-desktop
  locale_support: langpack
  name:
    en: Synthetic Desktop
  path: minimal.standard.squashfs
  size: 2048
  type: fsimage-layered
  variant: desktop
YAML
      ;;
  esac

  ( cd "$root/tree" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum >md5sum.txt )
  xorriso -as mkisofs -V SYNTHETIC -o "$root/base.iso" "$root/tree" >/dev/null 2>&1
  printf '%s' "$root/base.iso"
}

# --- single layout ----------------------------------------------------------
base=$(make_base single)
[[ -f "$base" ]] && ok "a synthetic single-layout base image is produced" || bad "synthetic base image"

work="$TMP/work-single"
mkdir -p "$work"
if forge_extract_iso "$base" "$work/iso" >/dev/null 2>&1; then
  ok "the base image extracts"
else
  bad "the base image extracts"
fi
check "the extracted tree is writable" "$([[ -w "$work/iso/casper" ]] && echo yes || echo no)" "yes"

forge_detect_layout "$work/iso" >/dev/null 2>&1
check "a single squashfs is detected as 'single'" "$FORGE_LAYOUT" "single"
check "the top layer is filesystem.squashfs" "$(basename "$FORGE_TOP_LAYER")" "filesystem.squashfs"

if forge_prepare_root "$work" >/dev/null 2>&1; then
  ok "the root filesystem unpacks"
else
  bad "the root filesystem unpacks"
fi
check "unpacked content is present" "$(cat "$work/rootfs/etc/os-release" 2>/dev/null)" "synthetic"

# A change made to the unpacked tree has to survive the repack.
printf 'added by the build\n' >"$work/rootfs/etc/isoforge-marker"
if forge_mksquashfs "$work/rootfs" "$work/iso/casper/filesystem.squashfs" >/dev/null 2>&1; then
  ok "the root filesystem repacks"
else
  bad "the root filesystem repacks"
fi
unsquashfs -d "$work/verify" "$work/iso/casper/filesystem.squashfs" >/dev/null 2>&1 || true
check "the change survives the repack" "$(cat "$work/verify/etc/isoforge-marker" 2>/dev/null)" "added by the build"

# md5sum.txt is what the "check disc for defects" boot entry verifies; a stale
# one fails on every rebuilt image.
before=$(md5sum "$work/iso/md5sum.txt" | awk '{print $1}')
forge_finalize_tree "$work/iso" "REBUILT" "$base" >/dev/null 2>&1
after=$(md5sum "$work/iso/md5sum.txt" | awk '{print $1}')
if [[ "$before" != "$after" ]]; then ok "md5sum.txt is regenerated"; else bad "md5sum.txt is regenerated"; fi
check ".disk/info keeps the base release metadata" "$(cat "$work/iso/.disk/info")" "Synthetic 24.04 release amd64"

out="$work/out.iso"
if forge_pack "$work/iso" "$base" "$out" "REBUILT" >/dev/null 2>&1; then
  ok "the tree packs back into an ISO"
else
  bad "the tree packs back into an ISO"
fi
if [[ -f "$out" ]] && is_valid_iso "$out"; then
  ok "the output is an ISO 9660 image"
else
  bad "the output is an ISO 9660 image"
fi
volid=$(xorriso -indev "$out" -pvd_info 2>&1 | sed -n "s/^Volume id *: *'\(.*\)'$/\1/p" | head -1)
check "the volume id is applied" "$volid" "REBUILT"

if grep -qE 'md5sum\.txt\.new|\./boot\.catalog|\./isolinux/boot\.cat' "$work/iso/md5sum.txt"; then
  bad "md5sum.txt excludes generated files"
else
  ok "md5sum.txt excludes generated files"
fi

if forge_verify "$out" >/dev/null 2>&1; then ok "the built image verifies"; else bad "the built image verifies"; fi
check "a checksum file is written alongside" "$([[ -f "$out.sha256" ]] && echo yes || echo no)" "yes"

# --- antiX layout ----------------------------------------------------------
base_antix=$(make_base antix)
work_antix="$TMP/work-antix"
mkdir -p "$work_antix"
forge_extract_iso "$base_antix" "$work_antix/iso" >/dev/null 2>&1
forge_detect_layout "$work_antix/iso" >/dev/null 2>&1
check "antiX linuxfs is detected as 'antix'" "$FORGE_LAYOUT" "antix"
if forge_prepare_root "$work_antix" >/dev/null 2>&1; then
  ok "the antiX root filesystem unpacks"
else
  bad "the antiX root filesystem unpacks"
fi
printf 'antiX change\n' >"$work_antix/rootfs/etc/isoforge-marker"
if forge_repack "$work_antix" "$work_antix/rootfs" "$work_antix/iso" >/dev/null 2>&1; then
  ok "the antiX root filesystem repacks"
else
  bad "the antiX root filesystem repacks"
fi
unsquashfs -d "$work_antix/verify" "$work_antix/iso/antiX/linuxfs" >/dev/null 2>&1 || true
check "the antiX change survives the repack" "$(cat "$work_antix/verify/etc/isoforge-marker" 2>/dev/null)" "antiX change"
if ( cd "$work_antix/iso/antiX" && md5sum -c linuxfs.md5 >/dev/null 2>&1 ); then
  ok "antiX linuxfs.md5 is regenerated"
else
  bad "antiX linuxfs.md5 is regenerated"
fi

# --- layered layout ---------------------------------------------------------
base2=$(make_base layered)
work2="$TMP/work-layered"
mkdir -p "$work2"
forge_extract_iso "$base2" "$work2/iso" >/dev/null 2>&1
forge_detect_layout "$work2/iso" >/dev/null 2>&1
check "stacked squashfs is detected as 'layered'" "$FORGE_LAYOUT" "layered"
# The image has three layers, but the installer uses minimal.standard, so the
# live layer above it is dropped. Building on top of the live layer would put
# the customization where the installer never looks.
check "layers above the install source are dropped" "${#FORGE_LAYER_PATHS[@]}" "2"
check "the build sits on the installer's layer" "$(basename "$FORGE_TOP_LAYER")" "minimal.standard.squashfs"
check "the install source stem is read from install-sources.yaml" \
  "$(forge_yaml_install_source_stem "$work2/iso/casper/install-sources.yaml")" "minimal.standard"

# The new layer must be registered or the installer carries it and ignores it.
FORGE_TOP_LAYER="$work2/iso/casper/minimal.standard.squashfs"
if forge_register_layer "$work2/iso" "minimal.standard.isoforge" >/dev/null 2>&1; then
  ok "install-sources.yaml is repointed at the new layer"
else
  bad "install-sources.yaml is repointed at the new layer"
fi
# The default entry is the one that moves, and it keeps the .squashfs form the
# file already used. The other entry must not be touched.
check "the default source now names the new layer" \
  "$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print([e["path"] for e in d if e.get("default")][0])' "$work2/iso/casper/install-sources.yaml" 2>/dev/null)" \
  "minimal.standard.isoforge.squashfs"
check "the other source is left alone" \
  "$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print([e["path"] for e in d if not e.get("default")][0])' "$work2/iso/casper/install-sources.yaml" 2>/dev/null)" \
  "minimal.squashfs"

# A layered image whose install-sources.yaml cannot be repointed must fail the
# build: the installer would keep the original layer and drop everything added.
rm -f "$work2/iso/casper/install-sources.yaml"
if forge_register_layer "$work2/iso" "minimal.standard.isoforge" >/dev/null 2>&1; then
  bad "a missing install-sources.yaml fails the build"
else
  ok "a missing install-sources.yaml fails the build"
fi

cat >"$work2/iso/casper/install-sources.yaml" <<'YAML'
- id: unrelated
  path: something-else.squashfs
YAML
if forge_register_layer "$work2/iso" "minimal.standard.isoforge" >/dev/null 2>&1; then
  bad "an install-sources.yaml that cannot be repointed fails the build"
else
  ok "an install-sources.yaml that cannot be repointed fails the build"
fi
check "the original install-sources.yaml is restored on failure" \
  "$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))[0]["path"])' "$work2/iso/casper/install-sources.yaml" 2>/dev/null)" \
  "something-else.squashfs"

# --- the volume id rewrite is literal ---------------------------------------
# A real base volume id looks like "Ubuntu 24.04.3 LTS amd64": as a regex those
# dots match anything, and a delimiter in the label would end the expression.
mkdir -p "$TMP/subst"
cat >"$TMP/subst/grub.cfg" <<'CFG'
linux /casper/vmlinuz boot=casper LABEL=Ubuntu 24.04.3 LTS amd64 quiet
# UbuntuX24Y04Z3 LTS amd64 must not be touched
CFG
forge_replace_literal "$TMP/subst/grub.cfg" "Ubuntu 24.04.3 LTS amd64" "REBUILT"
check "the exact label is replaced" \
  "$(grep -c 'LABEL=REBUILT' "$TMP/subst/grub.cfg")" "1"
check "text the dots would have matched is untouched" \
  "$(grep -c 'UbuntuX24Y04Z3' "$TMP/subst/grub.cfg")" "1"

printf 'a|b&c\\d\n' >"$TMP/subst/meta.cfg"
forge_replace_literal "$TMP/subst/meta.cfg" 'a|b&c\d' "SAFE"
check "a label full of metacharacters is replaced literally" \
  "$(cat "$TMP/subst/meta.cfg")" "SAFE"

# A repointed layer needs its own sidecar files. The manifest decides what a
# minimal install removes, so a missing or stale one gets minimal installs
# wrong; the vendor's remove lists are carried over as they are.
casper2="$work2/iso/casper"
printf 'base-pkg 1.0\n' >"$casper2/minimal.standard.manifest"
printf 'ubiquity\n'      >"$casper2/minimal.standard.manifest-remove"
printf 'casper\n'        >"$casper2/minimal.standard.manifest-minimal-remove"
# No chroot here, so dpkg-query cannot run and the fallback path is what is
# exercised: the previous manifest is carried over rather than left missing.
FORGE_CHROOT_DIR=""
forge_carry_sidecars "$casper2" "minimal.standard" "minimal.standard.isoforge" >/dev/null 2>&1
check "a failed manifest read leaves no partial file behind" \
  "$([[ -f "$casper2/minimal.standard.isoforge.manifest.isoforge-new" ]] && echo yes || echo no)" "no"
check "the carried manifest is the previous one, not an empty file" \
  "$(cat "$casper2/minimal.standard.isoforge.manifest" 2>/dev/null)" "base-pkg 1.0"
check "the new layer gets a manifest" \
  "$([[ -f "$casper2/minimal.standard.isoforge.manifest" ]] && echo yes || echo no)" "yes"
check "the remove list is carried over" \
  "$(cat "$casper2/minimal.standard.isoforge.manifest-remove" 2>/dev/null)" "ubiquity"
check "the minimal remove list is carried over" \
  "$(cat "$casper2/minimal.standard.isoforge.manifest-minimal-remove" 2>/dev/null)" "casper"

# python3 is needed at build time by forge_replace_literal, whichever backend
# read the recipe, so preflight must name it.
if printf '%s\n' "${FORGE_REQUIRED_TOOLS[@]}" | grep -qx python3; then
  ok "preflight requires python3"
else
  bad "preflight requires python3"
fi

# --- architecture detection -------------------------------------------------
mkdir -p "$TMP/arch/.disk"
printf 'Xubuntu 24.04.4 LTS "Noble Numbat" - Release amd64 (20250101)\n' >"$TMP/arch/.disk/info"
check "the architecture is read from .disk/info" "$(forge_detect_arch "$TMP/arch" /tmp/whatever.iso)" "amd64"
rm -f "$TMP/arch/.disk/info"
check "the architecture falls back to the filename" "$(forge_detect_arch "$TMP/arch" /tmp/thing-arm64.iso)" "arm64"
check "antiX 386 filenames are detected as i386" "$(forge_detect_arch "$TMP/arch" /tmp/antiX-26_386-core.iso)" "i386"
check "known architectures are accepted for --arch" "$(forge_arch_supported i386 && echo yes || echo no)" "yes"
check "unknown architectures are rejected for --arch" "$(forge_arch_supported mystery && echo yes || echo no)" "no"
check "an unknown architecture reads as empty" "$(forge_detect_arch "$TMP/arch" /tmp/mystery.iso)" ""

# xorriso's report contains `-e '--interval:...'` for the EFI boot image, and a
# bare -e in xargs input comes out as an empty field, which left the interval as
# a positional argument and made xorriso refuse the whole command.
mapfile -t split_args < <(printf -- "-eltorito-alt-boot\n-e '--interval:x:all::'\n-no-emul-boot\n" | python3 -c 'import shlex,sys
for word in shlex.split(sys.stdin.read()):
    print(word)')
check "a bare -e survives argument splitting" "${split_args[1]}" "-e"
check "its quoted value stays one word"       "${split_args[2]}" "--interval:x:all::"
check "nothing is lost"                       "${#split_args[@]}" "4"
if grep -q 'xargs -n1' "$REPO_ROOT/inc/forge/image.sh"; then
  bad "the pack step no longer splits arguments with xargs"
else
  ok "the pack step no longer splits arguments with xargs"
fi

# `mapfile < <(cmd)` cannot see cmd fail, so a split that errored would leave
# the argument list empty and xorriso would pack with no boot arguments: an
# image that mounts perfectly and boots nothing.
if grep -q 'mapfile -t args < <(' "$REPO_ROOT/inc/forge/image.sh"; then
  bad "boot-argument splitting detects its own failure"
else
  ok "boot-argument splitting detects its own failure"
fi
if grep -q 'parsed to nothing' "$REPO_ROOT/inc/forge/image.sh"; then
  ok "an empty split aborts the pack"
else
  bad "an empty split aborts the pack"
fi

# --- the chroot must not inherit the build host's environment ---------------
# A real build failed because NVM_DIR from a CI runner reached the chroot and
# pointed an installer at a host path. Anything not on the allow-list below
# would make an image depend on who built it.
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/chroot.sh"
allowed=$(sed -n '/env -i/,/bin\/bash -c/p' "$REPO_ROOT/inc/forge/chroot.sh" | grep -oE '^ *[A-Z_]+=' | tr -d ' =')
for leak in NVM_DIR GITHUB_ACTIONS SUDO_USER http_proxy PYTHONPATH; do
  if grep -qx -- "$leak" <<<"$allowed"; then
    bad "$leak is not passed into the chroot"
  else
    ok "$leak is not passed into the chroot"
  fi
done
for needed in PATH HOME LANG DEBIAN_FRONTEND; do
  if grep -qx -- "$needed" <<<"$allowed"; then
    ok "$needed is passed into the chroot"
  else
    bad "$needed is passed into the chroot"
  fi
done
if grep -q 'env -i' "$REPO_ROOT/inc/forge/chroot.sh"; then
  ok "the chroot starts from an empty environment"
else
  bad "the chroot starts from an empty environment"
fi

# The root filesystem is squashed between cleanup and teardown, so anything the
# build undoes only on the way out ships inside the image. A policy-rc.d
# returning 101 would refuse to start services on the installed machine.
cleanup_line=$(grep -n 'forge_chroot_cleanup' "$REPO_ROOT/inc/forge.sh" | grep -v '^.*#' | head -1 | cut -d: -f1)
repack_line=$(grep -n 'forge_repack ' "$REPO_ROOT/inc/forge.sh" | head -1 | cut -d: -f1)
if [[ -n "$cleanup_line" && -n "$repack_line" ]] && (( cleanup_line < repack_line )); then
  ok "the chroot is cleaned before the filesystem is squashed"
else
  bad "the chroot is cleaned before the filesystem is squashed"
fi
if grep -q 'forge_chroot_unscaffold' "$REPO_ROOT/inc/forge/chroot.sh"; then
  ok "cleanup removes the build's own scaffolding"
else
  bad "cleanup removes the build's own scaffolding"
fi

# --- a base that is not a live image ---------------------------------------
mkdir -p "$TMP/notlive/tree/random"
printf 'x\n' >"$TMP/notlive/tree/random/file"
xorriso -as mkisofs -o "$TMP/notlive/base.iso" "$TMP/notlive/tree" >/dev/null 2>&1
forge_extract_iso "$TMP/notlive/base.iso" "$TMP/notlive/iso" >/dev/null 2>&1
if forge_detect_layout "$TMP/notlive/iso" >/dev/null 2>&1; then
  bad "an image with no casper/ is rejected"
else
  ok "an image with no casper/ is rejected"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
