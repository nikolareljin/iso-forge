#!/usr/bin/env bash

LAST_DOWNLOAD_ERROR_TIME="${LAST_DOWNLOAD_ERROR_TIME:-}"
LAST_DOWNLOAD_ERROR_OPERATION="${LAST_DOWNLOAD_ERROR_OPERATION:-}"
LAST_DOWNLOAD_ERROR_SOURCE="${LAST_DOWNLOAD_ERROR_SOURCE:-}"
LAST_DOWNLOAD_ERROR_URL="${LAST_DOWNLOAD_ERROR_URL:-}"
LAST_DOWNLOAD_ERROR_LOG="${LAST_DOWNLOAD_ERROR_LOG:-}"
LAST_DOWNLOAD_ERROR_MESSAGE="${LAST_DOWNLOAD_ERROR_MESSAGE:-}"
LAST_DOWNLOAD_ERROR_RC="${LAST_DOWNLOAD_ERROR_RC:-}"

cleanup_tracked_download_log() {
  local log_path="${1:-}"
  local cleanup_errexit_was_on=0

  if [[ "$log_path" =~ ^/tmp/isoforge-download\.[A-Za-z0-9._-]+\.log$ ]] && [[ -f "$log_path" ]]; then
    if [[ $- == *e* ]]; then
      cleanup_errexit_was_on=1
      set +e
    fi
    rm -f -- "$log_path"
    if (( cleanup_errexit_was_on )); then
      set -e
    fi
  fi

  return 0
}

clear_last_download_error() {
  cleanup_tracked_download_log "${LAST_DOWNLOAD_ERROR_LOG:-}"
  LAST_DOWNLOAD_ERROR_TIME=""
  LAST_DOWNLOAD_ERROR_OPERATION=""
  LAST_DOWNLOAD_ERROR_SOURCE=""
  LAST_DOWNLOAD_ERROR_URL=""
  LAST_DOWNLOAD_ERROR_LOG=""
  LAST_DOWNLOAD_ERROR_MESSAGE=""
  LAST_DOWNLOAD_ERROR_RC=""
}

record_last_download_error() {
  local previous_log="${LAST_DOWNLOAD_ERROR_LOG:-}"
  local next_log="${5:-}"

  if [[ -n "$previous_log" && "$previous_log" != "$next_log" ]]; then
    cleanup_tracked_download_log "$previous_log"
  fi
  LAST_DOWNLOAD_ERROR_TIME="${1:-}"
  LAST_DOWNLOAD_ERROR_OPERATION="${2:-}"
  LAST_DOWNLOAD_ERROR_SOURCE="${3:-}"
  LAST_DOWNLOAD_ERROR_URL="${4:-}"
  LAST_DOWNLOAD_ERROR_LOG="${5:-}"
  LAST_DOWNLOAD_ERROR_MESSAGE="${6:-}"
  LAST_DOWNLOAD_ERROR_RC="${7:-}"
}

summarize_download_error_message() {
  local raw="${1:-}"
  local single_line
  local limit=200

  single_line=$(printf '%s\n' "$raw" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [[ -z "$single_line" ]]; then
    single_line="No additional error output captured."
  fi
  if (( ${#single_line} > limit )); then
    single_line="${single_line:0:limit-3}..."
  fi
  printf '%s\n' "$single_line"
}

has_last_download_error() {
  [[ -n "${LAST_DOWNLOAD_ERROR_TIME:-}" ]]
}

last_download_error_summary() {
  if ! has_last_download_error; then
    return 1
  fi

  printf 'Last download error: [%s] %s %s\n' \
    "$LAST_DOWNLOAD_ERROR_TIME" \
    "${LAST_DOWNLOAD_ERROR_OPERATION:-download}" \
    "${LAST_DOWNLOAD_ERROR_SOURCE:-unknown source}"
  printf 'Reason: %s\n' "${LAST_DOWNLOAD_ERROR_MESSAGE:-unknown error}"
  printf 'URL: %s\n' "${LAST_DOWNLOAD_ERROR_URL:-unknown}"
  printf 'Log: %s\n' "${LAST_DOWNLOAD_ERROR_LOG:-unavailable}"
}

show_last_download_error_dialog() {
  has_last_download_error || return 1
  dialog --title "Download Error" --msgbox "$(last_download_error_summary)" 14 76
}

print_last_download_error_cli() {
  has_last_download_error || return 1
  printf '%s\n' "$(last_download_error_summary)"
}

derive_download_output_name() {
  local url="$1"
  local output candidate

  output=$(basename -- "$url")
  if [[ "$output" != *.* ]]; then
    candidate=$(printf '%s\n' "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
    if [[ -n "$candidate" && "$candidate" != *://* && "$candidate" != */* ]]; then
      output="$candidate"
    fi
  fi
  printf '%s\n' "$output"
}

is_browser_url() {
  [[ "${1:-}" == https://* ]]
}

open_browser_url() {
  local url="$1"
  local opener

  is_browser_url "$url" || return 1
  for opener in xdg-open gio open; do
    command -v "$opener" >/dev/null 2>&1 || continue
    if [[ "$opener" == gio ]]; then
      gio open "$url" >/dev/null 2>&1 && return 0
    else
      "$opener" "$url" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

format_download_mib() {
  local bytes="${1:-0}"
  awk -v bytes="$bytes" 'BEGIN { printf "%.1f MiB", bytes / 1024 / 1024 }'
}

download_content_length() {
  local url="$1"

  if declare -F _dialog__fetch_content_length >/dev/null 2>&1; then
    _dialog__fetch_content_length "$url"
  else
    printf '0\n'
  fi
}

download_file_with_error_tracking() {
  local url="$1"
  local output="${2:-}"
  local operation="${3:-download}"
  local source_ref="${4:-$url}"
  local function_errexit_was_on=0

  if [[ $- == *e* ]]; then
    function_errexit_was_on=1
  fi

  if [[ -z "$output" ]]; then
    output=$(derive_download_output_name "$url")
  fi

  local dir tmpfile log_file mkdir_err
  dir=$(dirname -- "$output")
  if [[ -n "$dir" && "$dir" != "." ]] && [[ ! -d "$dir" ]]; then
    if ! mkdir_err=$(mkdir -p -- "$dir" 2>&1); then
      log_file=$(mktemp "/tmp/isoforge-download.XXXXXXXX.log")
      {
        printf 'Failed to create output directory "%s" for download.\n' "$dir"
        printf 'mkdir output:\n%s\n' "$mkdir_err"
      } >"$log_file"
      record_last_download_error \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$operation" \
        "$source_ref" \
        "$url" \
        "$log_file" \
        "Failed to create output directory \"$dir\"." \
        "1"
      if command -v dialog >/dev/null 2>&1; then
        show_last_download_error_dialog || true
      fi
      return 1
    fi
  fi
  tmpfile="${output}.part"
  log_file=$(mktemp "/tmp/isoforge-download.XXXXXXXX.log")
  rm -f -- "$tmpfile"

  local tool
  if command -v curl >/dev/null 2>&1; then
    tool="curl"
  elif command -v wget >/dev/null 2>&1; then
    tool="wget"
  else
    printf 'Neither curl nor wget is installed.\n' >"$log_file"
    record_last_download_error \
      "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
      "$operation" \
      "$source_ref" \
      "$url" \
      "$log_file" \
      "Neither curl nor wget is installed." \
      "127"
    if command -v dialog >/dev/null 2>&1; then
      show_last_download_error_dialog || true
    fi
    return 127
  fi

  local -a cmd
  if [[ "$tool" == "curl" ]]; then
    cmd=(curl -L --fail -sS -o "$tmpfile" -- "$url")
  else
    cmd=(wget -nv -O "$tmpfile" -- "$url")
  fi

  # A Content-Length header lets the gauge report actual progress. Some
  # mirrors and redirects do not provide one; those downloads remain at 0%
  # until completion instead of showing a misleading animated percentage.
  local total_bytes
  total_bytes=$(download_content_length "$url")
  [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0

  "${cmd[@]}" >"$log_file" 2>&1 &
  local pid=$!

  if command -v dialog >/dev/null 2>&1; then
    local pipefail_was_on=0 dialog_errexit_was_on=0 dlg_rc
    if shopt -qo pipefail; then
      pipefail_was_on=1
      set +o pipefail
    fi
    if [[ $- == *e* ]]; then
      dialog_errexit_was_on=1
      set +e
    fi
    (
      local percent=0 cur_bytes downloaded_mib total_mib
      while kill -0 "$pid" >/dev/null 2>&1; do
        cur_bytes=0
        if [[ -f "$tmpfile" ]]; then
          cur_bytes=$(wc -c <"$tmpfile" 2>/dev/null || echo 0)
        fi
        downloaded_mib=$(format_download_mib "$cur_bytes")
        if (( total_bytes > 0 )); then
          percent=$(( cur_bytes * 100 / total_bytes ))
          (( percent > 99 )) && percent=99
          total_mib=$(format_download_mib "$total_bytes")
        else
          percent=0
        fi
        printf 'XXX\n%d\n' "$percent" || break
        printf 'Downloading: %s\n' "$(basename -- "$output")" || break
        if (( total_bytes > 0 )); then
          printf 'Progress: %d%% (%s / %s)\n' "$percent" "$downloaded_mib" "$total_mib" || break
        else
          printf 'Downloaded: %s (total size unavailable)\n' "$downloaded_mib" || break
        fi
        printf 'XXX\n' || break
        sleep 1
      done
      printf 'XXX\n100\nFinalizing...\nXXX\n' || true
    ) 2>/dev/null | dialog --no-shadow --title "Downloading" --gauge "Preparing download..." 12 72 0
    dlg_rc=$?
    if (( dialog_errexit_was_on )); then
      set -e
    fi
    if (( pipefail_was_on )); then
      set -o pipefail
    fi
    if (( dlg_rc != 0 )); then
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      rm -f -- "$tmpfile"
      local err_preview="Download canceled by user via dialog."
      printf '%s\n' "$err_preview" >"$log_file"
      record_last_download_error \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$operation" \
        "$source_ref" \
        "$url" \
        "$log_file" \
        "$err_preview" \
        "$dlg_rc"
      if command -v dialog >/dev/null 2>&1; then
        show_last_download_error_dialog || true
      fi
      return "$dlg_rc"
    fi
  fi

  local rc
  if (( function_errexit_was_on )); then
    set +e
  fi
  wait "$pid"
  rc=$?
  if (( function_errexit_was_on )); then
    set -e
  fi
  if (( rc == 0 )); then
    local mv_rc rm_rc err_preview
    if (( function_errexit_was_on )); then
      set +e
    fi
    mv -f -- "$tmpfile" "$output"
    mv_rc=$?
    rm_rc=0
    if (( mv_rc == 0 )); then
      rm -f -- "$log_file"
      rm_rc=$?
    fi
    if (( function_errexit_was_on )); then
      set -e
    fi
    if (( mv_rc == 0 )); then
      if (( rm_rc != 0 )); then
        printf 'warning: failed to remove temporary download log: %s\n' "$log_file" >&2
      fi
      return 0
    fi
    if (( mv_rc != 0 )); then
      rm -f -- "$tmpfile"
    fi
    if (( mv_rc != 0 )); then
      printf '\nFailed to move downloaded file into place.\n' >>"$log_file"
    fi
    if (( rm_rc != 0 )); then
      printf '\nFailed to remove temporary download log.\n' >>"$log_file"
    fi
    if [[ -s "$log_file" ]]; then
      err_preview=$(summarize_download_error_message "$(tail -n 20 "$log_file")")
    else
      err_preview="No additional error output captured."
    fi
    record_last_download_error \
      "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
      "$operation" \
      "$source_ref" \
      "$url" \
      "$log_file" \
      "$err_preview" \
      "$mv_rc"
    if command -v dialog >/dev/null 2>&1; then
      show_last_download_error_dialog || true
    fi
    return "$mv_rc"
  fi

  rm -f -- "$tmpfile"
  local err_preview
  if [[ -s "$log_file" ]]; then
    err_preview=$(summarize_download_error_message "$(tail -n 20 "$log_file")")
  else
    err_preview="No additional error output captured."
  fi
  record_last_download_error \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
    "$operation" \
    "$source_ref" \
    "$url" \
    "$log_file" \
    "$err_preview" \
    "$rc"
  if command -v dialog >/dev/null 2>&1; then
    show_last_download_error_dialog || true
  fi
  return "$rc"
}
