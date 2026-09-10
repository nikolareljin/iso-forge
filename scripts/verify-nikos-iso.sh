#!/usr/bin/env bash
# Assert that a built image carries the NikOS post-install launcher while
# preserving the stock Xubuntu system it will install.
#
#   scripts/verify-nikos-iso.sh path/to/nikos-24.04-amd64.iso
#
# Checks the image itself (bootable, labelled, checksummed) and then the root
# filesystem inside it (the NikOS profile, launcher, and desktop entry).
# Everything here reads the artifact; nothing trusts the build log.
set -euo pipefail

ISO="${1:-}"
if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "usage: $0 <iso>" >&2
  exit 2
fi

# Run this as root. unsquashfs has to recreate device nodes to unpack a root
# filesystem, including the character devices overlayfs uses as whiteouts in a
# layered image, and unprivileged it skips them and then dies on the first
# hardlink to one:
#
#   create_inode: could not create character device ..., because you're not superuser!
#   FATAL ERROR: create_inode: failed to create hardlink, because No such file or directory
#
# Several gigabytes land here: the extracted image, one unpacked layer at a
# time, and the merged filesystem. Set TMPDIR to move it off a small /tmp.
if [[ "$(id -u)" -ne 0 ]]; then
  echo "WARNING: not running as root; unpacking a layered image will fail." >&2
  echo "         re-run with: sudo env TMPDIR=\"\$TMPDIR\" $0 $*" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
have()  { if [[ -e "$2" ]]; then ok "$1"; else bad "$1 (missing: ${2#"$WORK/root"})"; fi; }

echo "== image =="
size_mb=$(( $(stat -c%s "$ISO") / 1024 / 1024 ))
if (( size_mb > 1500 )); then
  ok "image is ${size_mb} MB, in the range a desktop image should be"
else
  bad "image is only ${size_mb} MB; a Xubuntu-derived desktop image should be well over 1500 MB"
fi

if file "$ISO" | grep -q "ISO 9660"; then ok "image is ISO 9660"; else bad "image is ISO 9660"; fi

# A remaster that loses its boot record produces a file that mounts fine and
# boots nothing, which is the failure this whole exercise is meant to prevent.
if xorriso -indev "$ISO" -report_el_torito plain 2>&1 | grep -q "^Boot record"; then
  ok "image carries an El Torito boot record"
else
  bad "image carries an El Torito boot record"
fi

volid=$(xorriso -indev "$ISO" -pvd_info 2>&1 | sed -n "s/^Volume id *: *'\(.*\)'$/\1/p" | head -1)
check "volume id is the recipe's" "$volid" "NIKOS_XUBUNTU_2404"

# The build writes a checksum beside the image. Recomputing it here is what
# turns that file into evidence: without this a truncated or corrupted image
# passes every other check, since they all read structure rather than bytes.
if [[ -f "$ISO.sha256" ]]; then
  ok "a checksum ships beside the image"
  recorded=$(awk '{print $1}' "$ISO.sha256")
  actual=$(sha256sum "$ISO" | awk '{print $1}')
  if [[ -n "$recorded" && "$recorded" == "$actual" ]]; then
    ok "the image matches its recorded checksum"
  else
    bad "the image matches its recorded checksum (recorded $recorded, actual $actual)"
  fi
else
  bad "a checksum ships beside the image (no $ISO.sha256)"
fi

echo
echo "== contents =="
xorriso -osirrox on -indev "$ISO" -extract / "$WORK/iso" >/dev/null 2>&1
chmod -R u+w "$WORK/iso" 2>/dev/null || true

have "casper/ is present" "$WORK/iso/casper"
check ".disk/info names the build" "$(cat "$WORK/iso/.disk/info" 2>/dev/null)" "NIKOS_XUBUNTU_2404"

# On a layered image the squashfs files are diffs, so inspecting any one of
# them says nothing: the base layer has no NikOS in it and the top layer has
# only what the build added. What matters is the stack the installer lays down,
# which install-sources.yaml names, so resolve that and unpack the whole chain.
casper="$WORK/iso/casper"
sources="$casper/install-sources.yaml"
declare -a layers=()

if [[ -f "$casper/filesystem.squashfs" ]]; then
  layers=("$casper/filesystem.squashfs")
  ok "root filesystem found: filesystem.squashfs"
elif [[ -f "$sources" ]]; then
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    bad "PyYAML is available to read install-sources.yaml"
    echo "     install python3-yaml (Debian/Ubuntu) or python3dist(pyyaml) (RPM)" >&2
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
  fi
  stem=$(python3 - "$sources" <<'PY' || true
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or []
found = []

def walk(node):
    if isinstance(node, dict):
        if isinstance(node.get("path"), str) and node["path"]:
            found.append((node.get("default") is True, node["path"]))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(doc)
if not found:
    # Nothing to report on. The caller turns an empty answer into a clean
    # failure; raising here would abort before the summary is printed.
    sys.exit(3)
found.sort(key=lambda pair: not pair[0])
path = found[0][1]
print(path[:-len(".squashfs")] if path.endswith(".squashfs") else path)
PY
)
  if [[ -z "$stem" ]]; then
    bad "install-sources.yaml names an install source"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
  fi
  ok "the installer's source is '$stem'"

  # Same ordering rule the build uses: names nest by prefix, so shortest first
  # puts each layer after the one it extends. Stop at the install source.
  while read -r f; do
    layers+=("$casper/$f")
    [[ "${f%.squashfs}" == "$stem" ]] && break
  done < <(find "$casper" -maxdepth 1 -name '*.squashfs' -printf '%f\n' | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-)

  if [[ "$(basename "${layers[-1]}" .squashfs)" != "$stem" ]]; then
    bad "the install source has a squashfs on the image"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
  fi
  ok "the installed system is ${#layers[@]} layer(s), topped by $(basename "${layers[-1]}")"

  # The build's own layer has to be the top one, or the installer would lay
  # down a system without any of it.
  if [[ "$stem" == *.isoforge ]]; then
    ok "the installer is pointed at the layer this build wrote"
  else
    bad "the installer is pointed at the layer this build wrote (points at '$stem')"
  fi
else
  bad "a squashfs is present in casper/"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

squash="${layers[-1]}"
manifest="${squash%.squashfs}.manifest"
[[ -f "$manifest" ]] || manifest="$casper/filesystem.manifest"
if [[ -f "$manifest" ]]; then
  ok "a package manifest ships beside it"
  for pkg in xubuntu-desktop-minimal lightdm; do
    if grep -q "^$pkg " "$manifest"; then
      ok "manifest lists $pkg"
    else
      bad "manifest lists $pkg"
    fi
  done
else
  bad "a package manifest ships beside it"
fi

echo
echo "== NikOS post-install launcher inside the root filesystem =="
# Unpack the layers in order into one directory, so what is inspected is the
# filesystem the installer would produce rather than any single diff.
# -no-xattrs so this works unprivileged; ownership is irrelevant here.
# Each layer is unpacked into its own directory and then merged, rather than
# unpacked on top of the previous one. unsquashfs cannot create a hardlink
# where a file already exists and aborts the whole layer partway through:
#
#   FATAL ERROR: create_inode: failed to create hardlink, because File exists
#
# which silently leaves out everything after the first collision. Merging with
# rsync applies the layers in order without that constraint, and each unpacked
# layer is removed once merged so only one extra copy is on disk at a time.
mkdir -p "$WORK/root"
i=0
for layer in "${layers[@]}"; do
  i=$((i + 1))
  if ! unsquashfs -n -no-xattrs -d "$WORK/layer$i" "$layer" >"$WORK/unsquash.log" 2>&1; then
    bad "layer $(basename "$layer") unpacks"
    tail -5 "$WORK/unsquash.log" >&2
    # A partial extraction is several gigabytes of no use to anything, and the
    # checks after this one are already tight on disk.
    rm -rf "${WORK:?}/layer$i"
    continue
  fi
  # overlayfs records a deleted path in an upper layer as a character device
  # with major:minor 0:0. Copying that over the directory it deletes is
  # impossible and beside the point: it means "this is gone". Apply the
  # deletion, drop the marker, then merge what is left.
  #
  # A real character device is left alone; only 0:0 is a whiteout.
  while IFS= read -r -d '' wh; do
    if [[ "$(stat -c '%t:%T' "$wh" 2>/dev/null)" == "0:0" ]]; then
      rel="${wh#"$WORK/layer$i/"}"
      rm -rf "${WORK:?}/root/$rel"
      rm -f "$wh"
    fi
  done < <(find "$WORK/layer$i" -type c -print0 2>/dev/null)

  if ! rsync -a "$WORK/layer$i/" "$WORK/root/" 2>"$WORK/merge.log"; then
    if ! cp -a "$WORK/layer$i/." "$WORK/root/" 2>>"$WORK/merge.log"; then
      # Reported rather than ignored: an incomplete merge makes every
      # assertion below report files as missing that are really present.
      bad "layer $(basename "$layer") merges into the root filesystem"
      tail -3 "$WORK/merge.log" >&2
    fi
  fi
  rm -rf "$WORK/layer$i"
done

# Checking the directory exists is not enough: mkdir made it, so a run where
# every layer failed to unpack still passed here and then reported four
# separate missing-file failures, which points at the image rather than at the
# unpack that actually broke.
missing_structure=()
for d in usr/bin usr/sbin etc var; do
  [[ -d "$WORK/root/$d" ]] || missing_structure+=("/$d")
done
if ((${#missing_structure[@]})); then
  bad "the root filesystem unpacks (no ${missing_structure[*]})"
  echo "     nothing below this point is meaningful; the layers did not unpack." >&2
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "the root filesystem unpacks"

# The image must carry a launcher and its profile, but not a preinstalled NikOS
# workstation. The native NikOS installer runs only after Xubuntu has completed
# its own installation and the user makes their profile and bundle selections.
have "the NikOS post-install launcher is installed" "$WORK/root/usr/local/bin/nikos-installer"
have "the Xubuntu 24.04 NikOS profile is installed" "$WORK/root/usr/share/iso-forge/nikos-profiles/xubuntu-24.04.env"
have "the Install NikOS desktop entry is installed" "$WORK/root/usr/share/applications/nikos-installer.desktop"

if grep -q '^Exec=nikos-installer$' "$WORK/root/usr/share/applications/nikos-installer.desktop" 2>/dev/null; then
  ok "the desktop entry starts the post-install launcher"
else
  bad "the desktop entry starts the post-install launcher"
fi
if grep -q 'boot=casper' "$WORK/root/usr/local/bin/nikos-installer" 2>/dev/null; then
  ok "the launcher refuses to run from the live session"
else
  bad "the launcher refuses to run from the live session"
fi
if [[ ! -e "$WORK/root/usr/local/bin/nikos" ]]; then
  ok "NikOS itself was not preinstalled into Xubuntu"
else
  bad "NikOS itself was not preinstalled into Xubuntu"
fi

# The build's own cleanup, verified on the artifact rather than trusted.
if [[ ! -s "$WORK/root/etc/machine-id" ]]; then
  ok "/etc/machine-id is empty, so installs do not share an identity"
else
  bad "/etc/machine-id is empty, so installs do not share an identity"
fi

# policy-rc.d returning 101 would refuse to start services on the installed
# machine, so it must not survive into the image.
if [[ -e "$WORK/root/usr/sbin/policy-rc.d" ]]; then
  bad "the build's policy-rc.d was removed"
else
  ok "the build's policy-rc.d was removed"
fi

# The build swaps in its own resolver to reach the network and puts the
# original back. The backup surviving means the swap was never undone, and the
# image is carrying the build host's DNS configuration.
if [[ -e "$WORK/root/etc/resolv.conf.isoforge-orig" ]]; then
  bad "the build's resolv.conf backup was cleaned up"
else
  ok "the build's resolv.conf backup was cleaned up"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
