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

# The guards in forge_integration_load, each proved to fail. Only the schema
# check above had ever been exercised, so the other four were assertions
# nothing had confirmed could fire -- a manifest missing its id, its playbook
# declaration, or the playbook file itself would have been caught by nothing
# in this suite.
# Each case asserts the message its own guard emits, not merely that the load
# failed. Written the loose way first, three of these four passed with the
# guard deleted: a manifest with no id is refused a step later by
# recipe_validate, one with no playbook key by the playbook-exists check, and a
# missing file by recipe_to_json. All still refused, none by the guard the test
# named -- so the guard could have been removed and the suite stayed green.
refuses() {
  local why="$1" expected="$2" path="$3" output
  if output=$(forge_integration_load "$path" 2>&1); then
    echo "accepted a manifest that $why" >&2
    exit 1
  fi
  if ! grep -qF -- "$expected" <<<"$output"; then
    echo "a manifest that $why was refused, but not by the guard for it" >&2
    echo "  expected to see: $expected" >&2
    echo "  got: $output" >&2
    exit 1
  fi
}

sed '/^integration:$/,+1d' "$tmpdir/isoforge.yml" >"$tmpdir/no-id.yml"
refuses "declares no integration.id" \
  "Integration manifest requires integration.id" "$tmpdir/no-id.yml"

sed '/^    playbook: /d' "$tmpdir/isoforge.yml" >"$tmpdir/no-playbook.yml"
refuses "declares no provisioning.ansible.playbook" \
  "Integration manifest requires provisioning.ansible.playbook" "$tmpdir/no-playbook.yml"

mkdir -p "$tmpdir/absent"
sed 's|playbook: playbooks/site.yml|playbook: playbooks/missing.yml|' \
  "$tmpdir/isoforge.yml" >"$tmpdir/absent/isoforge.yml"
refuses "names a playbook that is not in the tree" \
  "Integration playbook not found" "$tmpdir/absent"

refuses "does not exist" \
  "Integration manifest not found" "$tmpdir/nowhere/isoforge.yml"

# The happy path still loads after all of the above, so a guard that started
# rejecting everything would show up here rather than as a silent pass.
forge_integration_load "$tmpdir"
[[ "$(recipe_get '.recipe')" == 'manifest-regression' ]]

echo "integration manifest checks passed."
