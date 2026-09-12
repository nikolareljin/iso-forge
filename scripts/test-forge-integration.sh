#!/usr/bin/env bash
# Regression coverage for consumer-owned integration manifests.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/yaml.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/recipe.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/integration.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/customize.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/playbooks" "$tmpdir/overlay/live" "$tmpdir/iso/boot"
printf '%s\n' '- hosts: local' >"$tmpdir/playbooks/site.yml"
printf '%s\n' 'live-brand' >"$tmpdir/overlay/live/brand.txt"
cat >"$tmpdir/isoforge.yml" <<'YAML'
schema: 1
integration:
  id: manifest-regression
base:
  url: https://example.invalid/base.iso
output:
  name: manifest-regression
  volume_id: MANIFEST_REGRESSION
provisioning:
  ansible:
    playbook: playbooks/site.yml
overlay:
  target: []
  live:
    - src: overlay/live/brand.txt
      dest: /boot/brand.txt
YAML

forge_integration_load "$tmpdir"
[[ "$INTEGRATION_DIR" == "$tmpdir" ]]
[[ "$(recipe_get '.recipe')" == 'manifest-regression' ]]
[[ "$(recipe_get '.ansible.source')" == 'integration' ]]
[[ "$(recipe_get '.live_overlay[0].dest')" == '/boot/brand.txt' ]]
forge_live_overlay "$tmpdir" "$tmpdir/iso"
[[ "$(cat "$tmpdir/iso/boot/brand.txt")" == 'live-brand' ]]

for ref in "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})"; do
  forge_integration_require_commit "$ref"
done
for ref in "$(printf 'c%.0s' {1..39})" "$(printf 'd%.0s' {1..41})" "$(printf 'e%.0s' {1..63})" not-a-commit; do
  if forge_integration_require_commit "$ref"; then
    echo "accepted an invalid commit identifier" >&2
    exit 1
  fi
done

sed 's/schema: 1/schema: 2/' "$tmpdir/isoforge.yml" >"$tmpdir/invalid.yml"
if forge_integration_load "$tmpdir/invalid.yml" >/dev/null 2>&1; then
  echo "accepted an unsupported manifest schema" >&2
  exit 1
fi
