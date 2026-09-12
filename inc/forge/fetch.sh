#!/usr/bin/env bash
# Resolving the base image named by a recipe, and getting it onto disk.

# Set by forge_resolve_base.
FORGE_BASE_ISO=""

forge_catalog_url() {
  local id="$1"
  # `// empty`, not a bare .url: browser-only entries carry browser_url and no
  # url, and `jq -r` prints the literal "null" for a missing key -- which is
  # not empty, so callers accepted it and the build tried to download "null".
  jq -r --arg id "$id" '.distros[] | select(.id == $id) | .url // empty' "$CONFIG_FILE" | head -1
}

forge_catalog_ids() {
  jq -r '.distros[].id' "$CONFIG_FILE"
}

# Returns the actual ISO filename for direct URLs and SourceForge-style
# .../image.iso/download endpoints.
forge_base_filename() {
  local source="${1%%\?*}" name
  name=$(basename -- "$source")
  if [[ "$name" == "download" && "$source" == */download ]]; then
    name=$(basename -- "$(dirname -- "$source")")
  fi
  printf "%s\n" "$name"
}

# Downloads reuse the tracked downloader the interactive flows use, so a
# failure lands in the same session state and log the TUI already reports.
forge_download() {
  local url="$1" dest="$2"

  if [[ "$url" != https://* ]] && [[ "${ALLOW_INSECURE_HTTP_DOWNLOADS:-0}" != "1" ]]; then
    log_error "Refusing to download over plain HTTP: $url"
    log_error "Set ALLOW_INSECURE_HTTP_DOWNLOADS=1 to override; not recommended."
    return 2
  fi

  if [[ -f "$dest" ]]; then
    log_info "Base image already present, not re-downloading: $dest"
    return 0
  fi

  log_info "Downloading base image: $url"
  if ! download_file_with_error_tracking "$url" "$dest" "base image download" "$url"; then
    log_error "Base image download failed. $(last_download_error_summary 2>/dev/null || true)"
    return 1
  fi
}

# A base ISO is named one of three ways, and recipe_validate has already
# rejected a recipe that gives more than one.
forge_resolve_base() {
  local cache_dir="$1" base_override="${2:-}"
  local id url iso

  if [[ -n "$base_override" ]]; then
    iso="${base_override/#\~/$HOME}"
    if [[ ! -f "$iso" ]]; then
      log_error "Base ISO does not exist: $iso"
      return 2
    fi
    FORGE_BASE_ISO="$iso"
    log_info "Using local base image override: $FORGE_BASE_ISO"
    return 0
  fi

  id=$(recipe_get '.base.catalog_id // ""')
  url=$(recipe_get '.base.url // ""')
  iso=$(recipe_get '.base.iso // ""')

  if [[ -n "$iso" ]]; then
    iso="${iso/#\~/$HOME}"
    if [[ ! -f "$iso" ]]; then
      log_error "base.iso does not exist: $iso"
      return 2
    fi
    FORGE_BASE_ISO="$iso"
    log_info "Using local base image: $FORGE_BASE_ISO"
    return 0
  fi

  if [[ -n "$id" ]]; then
    url=$(forge_catalog_url "$id")
    if [[ -z "$url" ]]; then
      log_error "base.catalog_id '$id' is not in $CONFIG_FILE."
      log_error "Known ids: $(forge_catalog_ids | paste -sd' ' -)"
      return 2
    fi
  fi

  mkdir -p "$cache_dir"
  FORGE_BASE_ISO="$cache_dir/$(forge_base_filename "$url")"
  forge_download "$url" "$FORGE_BASE_ISO" || return $?
}

# An expected checksum is optional, but when the recipe gives one a mismatch
# has to stop the build: everything downstream trusts this image.
forge_verify_base() {
  local iso="$1"
  local expected
  expected=$(recipe_get '.base.sha256 // ""')

  if ! is_valid_iso "$iso"; then
    log_error "Not an ISO 9660 image: $iso"
    return 2
  fi

  if [[ -z "$expected" ]]; then
    log_warn "No base.sha256 in the recipe; the base image is not being verified."
    return 0
  fi

  log_info "Verifying base image checksum"
  local actual
  actual=$(sha256sum "$iso" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    log_error "Base image checksum mismatch for $iso"
    log_error "  expected $expected"
    log_error "  actual   $actual"
    return 1
  fi
  log_info "Base image checksum matches."
}
