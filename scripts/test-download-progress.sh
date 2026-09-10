#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  source "$ROOT_DIR/inc/download-state.sh"

  [[ "$(format_download_mib 0)" == "0.0 MiB" ]]
  [[ "$(format_download_mib 10485760)" == "10.0 MiB" ]]

  _dialog__fetch_content_length() { printf '52428800\n'; }
  [[ "$(download_content_length 'https://example.invalid/test.iso')" == "52428800" ]]

  unset -f _dialog__fetch_content_length
  [[ "$(download_content_length 'https://example.invalid/test.iso')" == "0" ]]
)
