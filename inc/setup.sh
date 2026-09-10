#!/usr/bin/env bash
# SCRIPT: setup.sh
# DESCRIPTION: Install dependencies needed by Isoforge.
# USAGE: setup [-h|--help] [PACKAGE...]
# PARAMETERS:
#   -h, --help  Show help and exit.
#   PACKAGE     Optional package names to install instead of default dependency set.
set -euo pipefail

# Install all dependencies for this repo using script-helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve repo root so script works whether run via root-level symlink or directly
if [[ -d "$SCRIPT_DIR/scripts/script-helpers" && -f "$SCRIPT_DIR/config.json" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../config.json" && -d "$SCRIPT_DIR/../scripts/script-helpers" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="$SCRIPT_DIR"
fi
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [[ -f "$REPO_ROOT/inc/cli-help.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/cli-help.sh"
else
  >&2 printf "Missing required CLI help file: %s\n" "$REPO_ROOT/inc/cli-help.sh"
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      isoforge_show_help setup
      exit 0
      ;;
  esac
done

ensure_helpers_library() {
  local helpers_path="${1:-$SCRIPT_HELPERS_DIR/helpers.sh}"
  if [[ ! -f "$helpers_path" ]]; then
    >&2 printf "Missing required helper library: %s\n" "$helpers_path"
    >&2 printf "Please install project submodules (e.g. run 'git submodule update --init --recursive') and retry.\n"
    exit 1
  fi
}

ensure_helpers_library "$SCRIPT_HELPERS_DIR/helpers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging deps os

print_info "Installing project dependencies via script-helpers ..."

# Debian-family systems name this package xz-utils; Fedora and Arch use xz.
xz_dependency_package() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' xz-utils
  else
    printf '%s\n' xz
  fi
}

# Default deps cover dialog, curl, jq, wget, util-linux, coreutils (for dd/stat).
# You can pass custom package names as arguments if needed.
if [[ $# -gt 0 ]]; then
  install_dependencies "$@"
else
  # Include common tools for Ventoy workflow and copying
  # exfatprogs for mounting Ventoy exFAT, rsync for copy with progress
  # xorriso/squashfs-tools/python3-yaml are what `./forge` needs to build an image
  install_dependencies dialog curl jq wget util-linux coreutils rsync exfatprogs parted \
    xorriso squashfs-tools python3-yaml "$(xz_dependency_package)" gzip bzip2
fi

print_success "Dependencies installed."
