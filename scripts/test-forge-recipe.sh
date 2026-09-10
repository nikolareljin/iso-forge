#!/usr/bin/env bash
# Recipe loading, merging and validation. No root, no network, no base image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [[ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]]; then
  echo "script-helpers not initialized; run ./update" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/yaml.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/recipe.sh"

CONFIG_FILE="$REPO_ROOT/config.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

write() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

# --- the shipped recipes must load -----------------------------------------
for r in "$REPO_ROOT"/recipes/*.yml; do
  case "$r" in *.local.yml) continue ;; esac
  if recipe_load "$r" >/dev/null 2>&1; then
    ok "$(basename "$r") loads and validates"
  else
    bad "$(basename "$r") does not validate"
  fi
done

recipe_load "$REPO_ROOT/recipes/nikos.yml" >/dev/null
if recipe_base_is_compatible 'xubuntu-24.04.4-desktop-amd64.iso'; then
  ok "NikOS accepts its Xubuntu 24.04 base"
else
  bad "NikOS accepts its Xubuntu 24.04 base"
fi
if recipe_base_is_compatible 'ubuntu-26.04-desktop-amd64.iso'; then
  bad "NikOS rejects an incompatible Ubuntu base"
else
  ok "NikOS rejects an incompatible Ubuntu base"
fi

# --- required fields --------------------------------------------------------
write "$TMP/no-name.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
EOF
if recipe_load "$TMP/no-name.yml" >/dev/null 2>&1; then
  bad "a recipe with no output.name is rejected"
else
  ok "a recipe with no output.name is rejected"
fi

write "$TMP/no-base.yml" <<'EOF'
recipe: t
output:
  name: t
EOF
if recipe_load "$TMP/no-base.yml" >/dev/null 2>&1; then
  bad "a recipe with no base is rejected"
else
  ok "a recipe with no base is rejected"
fi

write "$TMP/two-bases.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
  url: https://example.invalid/x.iso
output:
  name: t
EOF
if recipe_load "$TMP/two-bases.yml" >/dev/null 2>&1; then
  bad "two base sources are rejected"
else
  ok "two base sources are rejected"
fi

# A volume id over 32 bytes is truncated by xorriso, silently disagreeing with
# the boot entries that name it.
write "$TMP/long-volid.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: t
  volume_id: THIS_VOLUME_ID_IS_DEFINITELY_LONGER_THAN_THIRTY_TWO
EOF
if recipe_load "$TMP/long-volid.yml" >/dev/null 2>&1; then
  bad "an over-long volume_id is rejected"
else
  ok "an over-long volume_id is rejected"
fi

# --- an incomplete optional section is an error, not a silent skip ----------
write "$TMP/bad-ansible.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: t
ansible:
  repo: https://example.invalid/x
EOF
if recipe_load "$TMP/bad-ansible.yml" >/dev/null 2>&1; then
  bad "an ansible section with no playbook is rejected"
else
  ok "an ansible section with no playbook is rejected"
fi

# A volume id is substituted into the boot configuration, so it must not carry
# characters that are special to sed.
write "$TMP/bad-volid.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: t
  volume_id: "BAD|LABEL&HERE"
EOF
if recipe_load "$TMP/bad-volid.yml" >/dev/null 2>&1; then
  bad "a volume_id with sed metacharacters is rejected"
else
  ok "a volume_id with sed metacharacters is rejected"
fi

# output.label is used as the volume id when volume_id is absent, so the same
# rules have to reach it.
write "$TMP/label-as-volid.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: t
  label: NikOS 24.04
EOF
if recipe_load "$TMP/label-as-volid.yml" >/dev/null 2>&1; then
  bad "a label with spaces standing in for volume_id is rejected"
else
  ok "a label with spaces standing in for volume_id is rejected"
fi

write "$TMP/label-plus-volid.yml" <<'EOF'
recipe: t
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: t
  label: NikOS 24.04
  volume_id: NIKOS_2404
EOF
if recipe_load "$TMP/label-plus-volid.yml" >/dev/null 2>&1; then
  ok "a spaced label is fine once volume_id is set"
else
  bad "a spaced label is fine once volume_id is set"
fi

# --- package names are data, not shell --------------------------------------
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/customize.sh"
for good in git curl python3-yaml lib32z1 g++ "nginx=1.2.3" "curl/noble" "libc6:i386" "libgl1:amd64=1.2"; do
  if forge_valid_package_name "$good"; then ok "'$good' is accepted as a package name"; else bad "'$good' is accepted as a package name"; fi
done
for evil in 'git; rm -rf /' 'curl $(id)' 'a`id`' 'x|y' './relative' '-rf' 'pkg:$(id)' 'a:b:c:d'; do
  if forge_valid_package_name "$evil"; then bad "'$evil' is refused as a package name"; else ok "'$evil' is refused as a package name"; fi
done

# --- reading values ---------------------------------------------------------
write "$TMP/values.yml" <<'EOF'
recipe: values
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: values-img
  volume_id: VALUES
packages:
  install: [git, curl]
  remove: [nano]
EOF
recipe_load "$TMP/values.yml" >/dev/null
check "recipe name is read"          "$(recipe_get '.recipe')"           "values"
check "output.name is read"          "$(recipe_get '.output.name')"      "values-img"
check "install list is read"         "$(recipe_list '.packages.install' | paste -sd, -)" "git,curl"
check "an absent list yields nothing" "$(recipe_list '.flatpak' | wc -l | tr -d ' ')"    "0"

if recipe_has '.packages'; then ok "recipe_has finds a present section"; else bad "recipe_has finds a present section"; fi
if recipe_has '.ansible'; then bad "recipe_has rejects an absent section"; else ok "recipe_has rejects an absent section"; fi

# --- the local override layer ----------------------------------------------
write "$TMP/over.yml" <<'EOF'
recipe: over
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
output:
  name: original
  volume_id: ORIG
EOF
write "$TMP/over.local.yml" <<'EOF'
output:
  name: overridden
  volume_id: ORIG
EOF
recipe_load "$TMP/over.yml" >/dev/null
check "a local layer overrides the tracked recipe" "$(recipe_get '.output.name')" "overridden"
check "keys the local layer omits survive"         "$(recipe_get '.recipe')"      "over"

# --- catalog resolution -----------------------------------------------------
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/fetch.sh"
if [[ -n "$(forge_catalog_url Xubuntu_24_04_4_desktop_amd64)" ]]; then
  ok "the Xubuntu 24.04 base resolves from config.json"
else
  bad "the Xubuntu 24.04 base resolves from config.json"
fi
check "an unknown catalog id resolves to nothing" "$(forge_catalog_url definitely-not-a-distro)" ""

# --- dry-run agrees with the build about the base ---------------------------
# The dry-run's whole job is to answer "will this build?". It used to answer
# yes for a recipe whose configured base its own compatibility patterns
# forbid, because it only checked the --base-iso override.
forge_dry_run() { "$REPO_ROOT/inc/forge.sh" --recipe "$1" --dry-run >/dev/null 2>&1; }

write "$TMP/dry-catalog-ok.yml" <<'EOF'
recipe: dry-catalog-ok
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
compatibility:
  base_filename_patterns:
    - '^xubuntu-24\.04\.[0-9]+-desktop-amd64\.iso$'
output:
  name: dry-catalog-ok
EOF
if forge_dry_run "$TMP/dry-catalog-ok.yml"; then
  ok "dry-run accepts a catalog base its patterns allow"
else
  bad "dry-run accepts a catalog base its patterns allow"
fi

write "$TMP/dry-catalog-bad.yml" <<'EOF'
recipe: dry-catalog-bad
base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64
compatibility:
  base_filename_patterns:
    - '^kubuntu-25\.10-desktop-amd64\.iso$'
output:
  name: dry-catalog-bad
EOF
if forge_dry_run "$TMP/dry-catalog-bad.yml"; then
  bad "dry-run rejects a catalog base its patterns forbid"
else
  ok "dry-run rejects a catalog base its patterns forbid"
fi

write "$TMP/dry-url-bad.yml" <<'EOF'
recipe: dry-url-bad
base:
  url: https://example.invalid/isos/debian-13-netinst-amd64.iso
compatibility:
  base_filename_patterns:
    - '^xubuntu-24\.04\.[0-9]+-desktop-amd64\.iso$'
output:
  name: dry-url-bad
EOF
if forge_dry_run "$TMP/dry-url-bad.yml"; then
  bad "dry-run rejects a url base its patterns forbid"
else
  ok "dry-run rejects a url base its patterns forbid"
fi

write "$TMP/dry-no-patterns.yml" <<'EOF'
recipe: dry-no-patterns
base:
  url: https://example.invalid/isos/anything.iso
output:
  name: dry-no-patterns
EOF
if forge_dry_run "$TMP/dry-no-patterns.yml"; then
  ok "a recipe declaring no patterns is unaffected"
else
  bad "a recipe declaring no patterns is unaffected"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
