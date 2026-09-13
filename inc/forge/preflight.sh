#!/usr/bin/env bash
# Environment checks that must pass before anything is downloaded or written.

# Tools the remaster path cannot work without. Kept separate from the flashing
# dependencies in inc/setup.sh so a burn-only install stays small.
# python3 is not only the YAML backend: forge_replace_literal uses it for the
# volume-id rewrite whichever backend read the recipe, so a build cannot get
# far without it.
FORGE_REQUIRED_TOOLS=(xorriso unsquashfs mksquashfs rsync jq awk python3)

# Rough worst case for an Ubuntu desktop base: the extracted ISO tree, the
# unpacked root filesystem, the rebuilt squashfs and the output image all live
# in the work directory at once.
FORGE_MIN_FREE_GIB="${FORGE_MIN_FREE_GIB:-25}"

forge_require_root() {
  [[ "$(id -u)" -eq 0 ]]
}

forge_check_tools() {
  local missing=() t
  for t in "${FORGE_REQUIRED_TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    log_error "Missing required tool(s): ${missing[*]}"
    log_error "On Debian and Ubuntu: apt-get install xorriso squashfs-tools rsync jq python3 python3-yaml"
    return 2
  fi
}

forge_check_space() {
  local dir="$1"
  local probe="$dir"

  # df needs a path that exists; walk up to the nearest parent that does.
  while [[ ! -d "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done

  local free_kib free_gib
  free_kib=$(df -Pk "$probe" | awk 'NR==2 {print $4}')
  if [[ -z "$free_kib" ]]; then
    log_warn "Could not determine free space on $probe; continuing."
    return 0
  fi
  free_gib=$((free_kib / 1024 / 1024))
  if ((free_gib < FORGE_MIN_FREE_GIB)); then
    log_error "Work directory needs about ${FORGE_MIN_FREE_GIB} GiB free, $probe has ${free_gib} GiB."
    log_error "Point somewhere larger with --work-dir, or set FORGE_MIN_FREE_GIB if you know better."
    return 2
  fi
  log_info "Work directory $probe has ${free_gib} GiB free."
}

# Ubuntu images name their architecture in .disk/info; the filename carries it
# too. Returns nothing when neither says, and the check is then skipped rather
# than guessed at.
forge_detect_arch() {
  local iso_dir="$1" iso_path="$2"
  local text=""

  [[ -f "$iso_dir/.disk/info" ]] && text="$(cat "$iso_dir/.disk/info")"
  text+=" $(basename "$iso_path")"

  local a
  for a in amd64 arm64 i386 armhf ppc64el s390x riscv64; do
    if [[ "$text" == *"$a"* ]]; then
      printf '%s' "$a"
      return 0
    fi
  done
  if [[ "$(basename -- "$iso_path")" =~ (^|[_-])386([_.-]|$) ]]; then
    printf 'i386'
    return 0
  fi

  case "$text" in
    *x86_64*)  printf 'amd64' ;;
    *aarch64*) printf 'arm64' ;;
  esac
}

# Building for a different architecture than the host would need binfmt and a
# static qemu in the chroot. Say so plainly rather than failing deep inside apt.
forge_arch_supported() {
  case "$1" in
    amd64|arm64|i386|armhf|ppc64el|s390x|riscv64) return 0 ;;
    *) return 1 ;;
  esac
}

forge_check_arch() {
  local iso_arch="$1"
  local host_arch
  host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$host_arch" in
    x86_64) host_arch="amd64" ;;
    aarch64) host_arch="arm64" ;;
  esac
  if [[ -z "$iso_arch" ]]; then
    log_warn "Could not tell the base image's architecture; assuming it matches $host_arch."
    return 0
  fi
  if [[ "$host_arch" == "amd64" && "$iso_arch" == "i386" ]]; then
    if linux32 true >/dev/null 2>&1; then
      log_info "Using host i386 compatibility for the 32-bit base image."
      return 0
    fi
  fi

  if [[ "$iso_arch" != "$host_arch" ]]; then
    log_error "Base image is $iso_arch but this host is $host_arch."
    log_error "Cross-architecture builds are not supported; run this on an $iso_arch machine."
    return 2
  fi
}

forge_preflight() {
  local work_dir="$1"
  forge_check_tools || return $?
  forge_check_space "$work_dir" || return $?
}
