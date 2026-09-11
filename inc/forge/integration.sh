#!/usr/bin/env bash
# Generic consumer integration manifests. An integration lives in the consumer
# repository; IsoForge only understands this contract and never product names.

INTEGRATION_DIR=""
INTEGRATION_MANIFEST=""

forge_integration_require_commit() {
  [[ "$1" =~ ^[0-9a-fA-F]{40,64}$ ]]
}

forge_integration_checkout() {
  local repo="$1" ref="$2" dest="$3"
  forge_integration_require_commit "$ref" || {
    log_error "--ref must be an immutable full Git commit SHA"
    return 2
  }
  command -v git >/dev/null 2>&1 || { log_error "git is required for --integration-repo"; return 2; }
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  log_info "Checking out integration at requested revision"
  git clone --quiet --no-checkout --recurse-submodules "$repo" "$dest" || return 1
  git -C "$dest" checkout --quiet --detach "$ref" || return 1
  git -C "$dest" submodule update --init --recursive --quiet || return 1
}

forge_integration_load() {
  local path="$1" json
  [[ -d "$path" ]] && path="$path/isoforge.yml"
  [[ -f "$path" ]] || { log_error "Integration manifest not found: $(basename "$path")"; return 2; }
  json=$(recipe_to_json "$path") || return $?
  [[ "$(jq -r '.schema // empty' <<<"$json")" == "1" ]] || {
    log_error "Integration manifest requires schema: 1"
    return 2
  }
  [[ -n "$(jq -r '.integration.id // empty' <<<"$json")" ]] || {
    log_error "Integration manifest requires integration.id"
    return 2
  }
  [[ -n "$(jq -r '.provisioning.ansible.playbook // empty' <<<"$json")" ]] || {
    log_error "Integration manifest requires provisioning.ansible.playbook"
    return 2
  }
  RECIPE_JSON=$(jq '{recipe: .integration.id, base: .base, output: .output,
      compatibility: .compatibility, packages: (.packages // {}),
      sources: (.sources // {}), flatpak: (.flatpak // []),
      overlay: (.overlay.target // []), live_overlay: (.overlay.live // []),
      hooks: (.hooks // {}), ansible: (.provisioning.ansible | . + {source: "integration"})}' <<<"$json")
  INTEGRATION_MANIFEST="$path"
  INTEGRATION_DIR="$(cd "$(dirname "$path")" && pwd)"
  local playbook
  playbook=$(jq -r '.provisioning.ansible.playbook' <<<"$json")
  [[ -f "$INTEGRATION_DIR/$playbook" ]] || { log_error "Integration playbook not found: $playbook"; return 2; }
  recipe_validate "$path"
}
