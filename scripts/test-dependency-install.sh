#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$ROOT_DIR"
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  source ./inc/isoforge.sh

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  REPO_ROOT="$tmpdir"
  DIALOG_WIDTH=72

  dialog_args_file="$tmpdir/dialog-args"
  dialog() {
    printf '%s\n' "$*" >"$dialog_args_file"
    cat >/dev/null
  }

  install_dependencies() {
    printf 'Refreshing package metadata\n'
    printf 'Installing: %s\n' "$*"
    return "${INSTALL_RC:-0}"
  }

  INSTALL_RC=0
  deps_install_with_dialog jq curl
  dialog_args="$(cat "$dialog_args_file")"
  [[ "$dialog_args" == *"--programbox"* ]]
  [[ "$dialog_args" != *"--gauge"* ]]
  [[ "$(cat "$REPO_ROOT/.deps_install.log")" == *"Installing: jq curl"* ]]

  INSTALL_RC=23
  if deps_install_with_dialog jq; then
    echo "expected installer failure to be returned" >&2
    exit 1
  fi
  [[ "$(cat "$REPO_ROOT/.deps_install.log")" == *"Installing: jq"* ]]

  [[ "$(declare -f ensure_deps)" != *"chafa"* ]]
)
