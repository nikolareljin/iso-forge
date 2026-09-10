#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$ROOT_DIR"
  export ISOFORGE_DISABLE_EXIT_TRAP=1
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  source ./inc/isoforge.sh
  download_content_length() { printf '0\n'; }

  tmp_log="$tmpdir/error.log"
  record_last_download_error \
    "2026-03-11 10:15:00 EDT" \
    "single-download" \
    "Ubuntu_24_04" \
    "https://example.invalid/ubuntu.iso" \
    "$tmp_log" \
    "curl: (22) The requested URL returned error: 404" \
    "22"

  summary="$(show_summary)"
  [[ "$summary" == *"Last download error:"* ]]
  [[ "$summary" == *"single-download Ubuntu_24_04"* ]]
  [[ "$summary" == *"$tmp_log"* ]]
  [[ "$summary" == *"404"* ]]

  cli_summary="$(print_last_download_error_cli)"
  [[ "$cli_summary" == *"Last download error:"* ]]
  [[ "$cli_summary" == *"$tmp_log"* ]]

  success_file="$tmpdir/success.bin"
  fakebin="$tmpdir/fakebin"
  mkdir -p "$fakebin"
  ln -s "$(command -v bash)" "$fakebin/bash"
  for tool in basename dirname mkdir mktemp mv rm wc date tail; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
: >"$out"
EOF
  chmod +x "$fakebin/curl"
  old_path="$PATH"
  set +e
  PATH="$fakebin"
  download_file_with_error_tracking "https://example.invalid/success.bin" "$success_file" "batch-download" "DemoItem"
  success_rc=$?
  PATH="$old_path"
  [[ "$success_rc" -eq 0 ]]
  [[ $- != *e* ]]
  set -e

  cli_summary="$(print_last_download_error_cli)"
  [[ "$cli_summary" == *"Ubuntu_24_04"* ]]
  [[ "$cli_summary" == *"$tmp_log"* ]]

  dash_url_file="$tmpdir/leading-dash.bin"
  fakebin_dash_url="$tmpdir/fakebin-dash-url"
  mkdir -p "$fakebin_dash_url"
  ln -s "$(command -v bash)" "$fakebin_dash_url/bash"
  for tool in basename dirname mkdir mktemp mv rm wc date tail; do
    ln -s "$(command -v "$tool")" "$fakebin_dash_url/$tool"
  done
  cat >"$fakebin_dash_url/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
seen_double_dash=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    --)
      seen_double_dash=1
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done
if [[ "$seen_double_dash" -ne 1 ]]; then
  echo "missing -- before URL" >&2
  exit 1
fi
if [[ "${1:-}" != "-https://example.invalid/dash.bin" ]]; then
  echo "unexpected URL: ${1:-}" >&2
  exit 1
fi
: >"$out"
EOF
  chmod +x "$fakebin_dash_url/curl"
  old_path="$PATH"
  PATH="$fakebin_dash_url"
  download_file_with_error_tracking "-https://example.invalid/dash.bin" "$dash_url_file" "dash-download" "DashItem"
  PATH="$old_path"
  [[ -f "$dash_url_file" ]]
  [[ "$(derive_download_output_name "-https://example.invalid/dash.bin")" == "dash.bin" ]]

  clear_last_download_error

  mkdir_fail_root="$tmpdir/mkdir-fail"
  fakebin_mkdir_fail="$tmpdir/fakebin-mkdir-fail"
  mkdir -p "$fakebin_mkdir_fail"
  ln -s "$(command -v bash)" "$fakebin_mkdir_fail/bash"
  for tool in basename dirname mktemp mv rm wc date tail; do
    ln -s "$(command -v "$tool")" "$fakebin_mkdir_fail/$tool"
  done
  cat >"$fakebin_mkdir_fail/mkdir" <<'EOF'
#!/usr/bin/env bash
echo "permission denied" >&2
exit 1
EOF
  chmod +x "$fakebin_mkdir_fail/mkdir"
  old_path="$PATH"
  PATH="$fakebin_mkdir_fail"
  if download_file_with_error_tracking "https://example.invalid/mkdir.bin" "$mkdir_fail_root/out.bin" "mkdir-download" "MkdirItem"; then
    echo "expected mkdir failure" >&2
    exit 1
  fi
  PATH="$old_path"
  cli_summary="$(print_last_download_error_cli)"
  [[ "$cli_summary" == *"mkdir-download MkdirItem"* ]]
  [[ "$cli_summary" == *"Failed to create output directory"* ]]

  clear_last_download_error

  cancel_file="$tmpdir/cancel.bin"
  fakebin_dialog="$tmpdir/fakebin-dialog"
  mkdir -p "$fakebin_dialog"
  ln -s "$(command -v bash)" "$fakebin_dialog/bash"
  for tool in basename cat dirname mkdir mktemp mv rm wc date tail sleep; do
    ln -s "$(command -v "$tool")" "$fakebin_dialog/$tool"
  done
  cat >"$fakebin_dialog/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'partial' >"$out"
sleep 2
EOF
  cat >"$fakebin_dialog/dialog" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fakebin_dialog/curl" "$fakebin_dialog/dialog"
  old_path="$PATH"
  PATH="$fakebin_dialog"
  if download_file_with_error_tracking "https://example.invalid/cancel.bin" "$cancel_file" "dialog-download" "DialogItem"; then
    echo "expected dialog cancellation" >&2
    exit 1
  else
    rc=$?
  fi
  PATH="$old_path"
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$cancel_file.part" ]]
  cli_summary="$(print_last_download_error_cli)"
  [[ "$cli_summary" == *"dialog-download DialogItem"* ]]
  [[ "$cli_summary" == *"Download canceled by user via dialog."* ]]

  clear_last_download_error

  cleanup_warn_file="$tmpdir/cleanup-warn.bin"
  cleanup_warn_log_capture="$tmpdir/cleanup-warn.stderr"
  fakebin_cleanup_warn="$tmpdir/fakebin-cleanup-warn"
  real_rm="$(command -v rm)"
  mkdir -p "$fakebin_cleanup_warn"
  ln -s "$(command -v bash)" "$fakebin_cleanup_warn/bash"
  for tool in basename dirname mkdir mktemp mv wc date tail cat; do
    ln -s "$(command -v "$tool")" "$fakebin_cleanup_warn/$tool"
  done
  cat >"$fakebin_cleanup_warn/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
: >"$out"
EOF
  cat >"$fakebin_cleanup_warn/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == /tmp/isoforge-download.*.log ]]; then
    echo "rm failed intentionally" >&2
    exit 1
  fi
done
exec "$REAL_RM" "$@"
EOF
  chmod +x "$fakebin_cleanup_warn/curl" "$fakebin_cleanup_warn/rm"
  old_path="$PATH"
  REAL_RM="$real_rm" PATH="$fakebin_cleanup_warn"
  if ! download_file_with_error_tracking "https://example.invalid/cleanup-warn.bin" "$cleanup_warn_file" "cleanup-download" "CleanupItem" 2>"$cleanup_warn_log_capture"; then
    echo "expected cleanup warning path to stay successful" >&2
    exit 1
  fi
  PATH="$old_path"
  [[ -f "$cleanup_warn_file" ]]
  [[ -z "${LAST_DOWNLOAD_ERROR_TIME:-}" ]]
  [[ "$(cat "$cleanup_warn_log_capture")" == *"warning: failed to remove temporary download log:"* ]]

  flow_log="$tmpdir/flow-error.log"
  record_last_download_error \
    "2026-03-11 10:19:00 EDT" \
    "flow-download" \
    "FlowItem" \
    "https://example.invalid/flow.iso" \
    "$flow_log" \
    "flow failure" \
    "1"
  fakebin_flow="$tmpdir/fakebin-flow"
  mkdir -p "$fakebin_flow"
  ln -s "$(command -v bash)" "$fakebin_flow/bash"
  for tool in jq mkdir sed mktemp rm; do
    ln -s "$(command -v "$tool")" "$fakebin_flow/$tool"
  done
  cat >"$fakebin_flow/dialog" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fakebin_flow/dialog"
  old_path="$PATH"
  old_config_file="$CONFIG_FILE"
  flow_config="$tmpdir/config.json"
  cat >"$flow_config" <<'EOF'
{"distros":[{"id":"DemoISO","label":"Demo ISO","url":"https://example.invalid/demo.iso"}]}
EOF
  CONFIG_FILE="$flow_config"
  PATH="$fakebin_flow"
  select_image_from_config || true
  select_images_from_config_multi || true
  PATH="$old_path"
  CONFIG_FILE="$old_config_file"
  cli_summary="$(print_last_download_error_cli)"
  [[ "$cli_summary" == *"flow-download FlowItem"* ]]
  [[ "$cli_summary" == *"$flow_log"* ]]

  tracked_log="$(mktemp "/tmp/isoforge-download.XXXXXXXX.log")"
  printf 'temporary tracked failure\n' >"$tracked_log"
  record_last_download_error \
    "2026-03-11 10:20:00 EDT" \
    "tracked-download" \
    "TrackedItem" \
    "https://example.invalid/tracked.iso" \
    "$tracked_log" \
    "tracked failure" \
    "1"
  [[ -f "$tracked_log" ]]
  clear_last_download_error
  [[ ! -e "$tracked_log" ]]

  first_tracked_log="$(mktemp "/tmp/isoforge-download.XXXXXXXX.log")"
  second_tracked_log="$(mktemp "/tmp/isoforge-download.XXXXXXXX.log")"
  printf 'first tracked failure\n' >"$first_tracked_log"
  printf 'second tracked failure\n' >"$second_tracked_log"
  record_last_download_error \
    "2026-03-11 10:21:00 EDT" \
    "tracked-download" \
    "TrackedItemOne" \
    "https://example.invalid/tracked-one.iso" \
    "$first_tracked_log" \
    "first tracked failure" \
    "1"
  record_last_download_error \
    "2026-03-11 10:22:00 EDT" \
    "tracked-download" \
    "TrackedItemTwo" \
    "https://example.invalid/tracked-two.iso" \
    "$second_tracked_log" \
    "second tracked failure" \
    "2"
  [[ ! -e "$first_tracked_log" ]]
  [[ -e "$second_tracked_log" ]]

  clear_last_download_error
  [[ ! -e "$second_tracked_log" ]]

  stale_log="$tmpdir/stale-error.log"
  record_last_download_error \
    "2026-03-11 10:23:00 EDT" \
    "stale-download" \
    "StaleItem" \
    "https://example.invalid/stale.iso" \
    "$stale_log" \
    "stale failure" \
    "1"
  warning_capture="$tmpdir/multi-warning.txt"
  fakebin_multi_warning="$tmpdir/fakebin-multi-warning"
  mkdir -p "$fakebin_multi_warning"
  ln -s "$(command -v bash)" "$fakebin_multi_warning/bash"
  for tool in jq mkdir sed cat mktemp rm; do
    ln -s "$(command -v "$tool")" "$fakebin_multi_warning/$tool"
  done
  cat >"$fakebin_multi_warning/dialog" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --stdout)
    printf '"DemoISO"\n'
    exit 0
    ;;
  --title)
    if [[ "${2:-}" == "Download completed with warnings" && "${3:-}" == "--msgbox" ]]; then
      printf '%s\n' "${4:-}" >"$WARNING_CAPTURE_FILE"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$fakebin_multi_warning/dialog"
  multi_warning_config="$tmpdir/multi-warning-config.json"
  cat >"$multi_warning_config" <<'EOF'
{"distros":[{"id":"DemoISO","label":"Demo ISO","url":"ftp://example.invalid/demo.iso"}]}
EOF
  old_path="$PATH"
  old_config_file="$CONFIG_FILE"
  CONFIG_FILE="$multi_warning_config"
  WARNING_CAPTURE_FILE="$warning_capture" PATH="$fakebin_multi_warning" select_images_from_config_multi || true
  PATH="$old_path"
  CONFIG_FILE="$old_config_file"
  [[ -f "$warning_capture" ]]
  warning_text="$(cat "$warning_capture")"
  [[ "$warning_text" == *"If a download fails, the latest failure remains visible in the main status panel."* ]]
  [[ "$warning_text" != *"The latest download failure remains visible in the main status panel."* ]]

  clear_last_download_error
  summary="$(show_summary)"
  [[ "$summary" != *"Last download error:"* ]]
)
