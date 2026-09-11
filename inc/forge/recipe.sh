#!/usr/bin/env bash
# Recipe loading and validation.
#
# A recipe is YAML. It is converted once to JSON (see inc/forge/yaml.sh) and
# read from there with `jq`, so the rest of the build reuses the same jq-based
# config handling the download and flash flows already use.

RECIPE_JSON=""

recipe_require_tools() {
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required. Run ./setup"
    return 2
  fi
  forge_yaml_require >/dev/null || return $?
}

recipe_to_json() {
  local path="$1"
  local out
  if ! out=$(forge_yaml_to_json "$path" 2>&1); then
    log_error "Could not read recipe as YAML: $path"
    log_error "$out"
    return 2
  fi
  printf '%s' "$out"
}

recipe_get() {
  jq -r "$1" <<<"$RECIPE_JSON"
}

# Arrays come back one element per line. An absent or null key yields nothing,
# so callers can always `mapfile` without checking first.
recipe_list() {
  jq -r "$1 // [] | .[]" <<<"$RECIPE_JSON"
}

recipe_has() {
  [[ "$(jq -r "$1 // \"null\" | if . == \"null\" then \"no\" else \"yes\" end" <<<"$RECIPE_JSON")" == "yes" ]]
}

recipe_base_is_compatible() {
  local base_path="$1" base_name pattern
  local -a patterns=()
  mapfile -t patterns < <(recipe_list '.compatibility.base_filename_patterns')
  [[ ${#patterns[@]} -gt 0 ]] || return 0
  # Strip a query string first: forge_resolve_base caches the download as
  # basename "${url%%\?*}" (inc/forge/fetch.sh), so a supported URL ending
  # "...iso?download=1" must be matched on "...iso" or dry-run and build
  # disagree about the same base.
  base_name=$(basename -- "${base_path%%\?*}")
  # compatibility.base_filename_patterns uses POSIX extended regular
  # expressions. The interactive ISO creator uses the same dialect.
  for pattern in "${patterns[@]}"; do
    [[ "$base_name" =~ $pattern ]] && return 0
  done
  return 1
}

recipe_validate() {
  local path="$1"
  local errors=()

  [[ "$(recipe_get '.recipe // ""')" != "" ]] || errors+=("recipe: required, a short name for this build")

  local base_id base_url base_iso
  base_id=$(recipe_get '.base.catalog_id // ""')
  base_url=$(recipe_get '.base.url // ""')
  base_iso=$(recipe_get '.base.iso // ""')
  if [[ -z "$base_id" && -z "$base_url" && -z "$base_iso" ]]; then
    errors+=("base: needs exactly one of catalog_id, url or iso")
  fi
  local given=0
  [[ -n "$base_id" ]] && given=$((given + 1))
  [[ -n "$base_url" ]] && given=$((given + 1))
  [[ -n "$base_iso" ]] && given=$((given + 1))
  if ((given > 1)); then
    errors+=("base: catalog_id, url and iso are mutually exclusive; $given were given")
  fi

  [[ "$(recipe_get '.output.name // ""')" != "" ]] || errors+=("output.name: required, the ISO filename without .iso")

  if recipe_has '.compatibility'; then
    local -a compatibility_patterns=()
    mapfile -t compatibility_patterns < <(recipe_list '.compatibility.base_filename_patterns')
    [[ ${#compatibility_patterns[@]} -gt 0 ]] || errors+=("compatibility.base_filename_patterns: required when compatibility is present")
    local compatibility_pattern regex_status
    for compatibility_pattern in "${compatibility_patterns[@]}"; do
      if grep -Eq -- "$compatibility_pattern" </dev/null; then
        :
      else
        regex_status=$?
        (( regex_status == 2 )) && errors+=("compatibility.base_filename_patterns: invalid POSIX ERE: $compatibility_pattern")
      fi
    done
  fi

  # The build falls back to output.label when volume_id is absent, so the rules
  # below apply to whichever value ends up on the image. A label like
  # "Custom OS 24.04" is fine as a label and not fine as a volume id, and the error
  # names the field to set.
  local vol field
  vol=$(recipe_get '.output.volume_id // ""')
  field="output.volume_id"
  if [[ -z "$vol" ]]; then
    vol=$(recipe_get '.output.label // ""')
    field="output.label (used as the volume id because output.volume_id is not set)"
  fi

  # Over 32 bytes is silently truncated by xorriso, which then disagrees with
  # the boot entries naming it.
  if [[ -n "$vol" && ${#vol} -gt 32 ]]; then
    errors+=("$field: ${#vol} characters; ISO 9660 allows at most 32")
  fi
  # Restricted so it is inert where it is substituted into the boot config.
  if [[ -n "$vol" && ! "$vol" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    errors+=("$field: only letters, digits, underscore, dot and dash; set output.volume_id explicitly if the label needs spaces")
  fi

  if recipe_has '.distrodeck'; then
    local export_path
    export_path=$(recipe_get '.distrodeck.export // ""')
    [[ -n "$export_path" ]] || errors+=("distrodeck.export: required when a distrodeck section is present")
  fi

  if recipe_has '.ansible'; then
    [[ "$(recipe_get '.ansible.repo // .ansible.source // ""')" != "" ]] || errors+=("ansible.repo or ansible.source: required when an ansible section is present")
    [[ "$(recipe_get '.ansible.playbook // ""')" != "" ]] || errors+=("ansible.playbook: required when an ansible section is present")
  fi

  if ((${#errors[@]})); then
    log_error "Recipe is not valid: $path"
    local e
    for e in "${errors[@]}"; do
      log_error "  $e"
    done
    return 2
  fi
}

# Load recipe.yml, then recipe.local.yml on top of it when present. The local
# layer is the same idea as a consumer's local configuration: tracked defaults, untracked
# machine-specific overrides, deep-merged rather than replaced wholesale.
recipe_load() {
  local path="$1"
  local base_json overlay_json local_path

  recipe_require_tools || return $?
  if [[ ! -f "$path" ]]; then
    log_error "Recipe not found: $path"
    return 2
  fi

  base_json=$(recipe_to_json "$path") || return $?

  # foo.yml -> foo.local.yml, foo.yaml -> foo.local.yaml
  case "$path" in
    *.yaml) local_path="${path%.yaml}.local.yaml" ;;
    *.yml)  local_path="${path%.yml}.local.yml" ;;
    *)      local_path="$path.local" ;;
  esac
  if [[ -f "$local_path" ]]; then
    log_info "Applying local overrides from $(basename "$local_path")"
    overlay_json=$(recipe_to_json "$local_path") || return $?
    RECIPE_JSON=$(jq -s '.[0] * .[1]' <<<"$base_json"$'\n'"$overlay_json")
  else
    RECIPE_JSON="$base_json"
  fi

  recipe_validate "$path" || return $?
}
