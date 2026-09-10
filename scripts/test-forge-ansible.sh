#!/usr/bin/env bash
# Regression coverage for the generic Ansible image-builder path.
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
source "$REPO_ROOT/inc/forge/chroot.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/inc/forge/ansible.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/ansible.yml" <<'YAML'
recipe: ansible-regression
base:
  url: https://example.invalid/base.iso
output:
  name: ansible-test
  volume_id: ANSIBLE_TEST
ansible:
  repo: https://example.invalid/ansible-repo.git
  ref: 1.2.3
  playbook: site.yml
  extra_vars:
    feature_list: [alpha, beta]
    feature_map: {enabled: true}
YAML
recipe_load "$tmpdir/ansible.yml"

[[ "$(recipe_get '.ansible.ref')" == '1.2.3' ]]
[[ "$(recipe_get '.ansible.extra_vars.feature_list | type')" == 'array' ]]
[[ "$(recipe_get '.ansible.extra_vars.feature_map | type')" == 'object' ]]
grep -Fq 'vars_json=$(jq -c --arg home "$skel_home"' "$REPO_ROOT/inc/forge/ansible.sh"
grep -Fq "args+=(-e "\$vars_json")" "$REPO_ROOT/inc/forge/ansible.sh"
[[ "$(grep -c 'export HOME=' "$REPO_ROOT/inc/forge/ansible.sh")" == 2 ]]

forge_in_chroot() {
  printf 'play #1 (local): p\tTAGS: []\n      TASK TAGS: [ai.local, plain]\n'
}
forge_ansible_check_tags /opt/test site.yml inventory/local skip_tags 'ai.local'
if forge_ansible_check_tags /opt/test site.yml inventory/local skip_tags 'ai-local' >/dev/null 2>&1; then
  exit 1
fi
if forge_ansible_check_tags /opt/test site.yml inventory/local skip_tags 'ai.*' >/dev/null 2>&1; then
  exit 1
fi
