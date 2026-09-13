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
source "$REPO_ROOT/inc/forge/customize.sh"
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
grep -Fq 'args+=(-e "$vars_json")' "$REPO_ROOT/inc/forge/ansible.sh"

FORGE_LAYOUT=antix
prepared_command=""
forge_in_chroot() {
  prepared_command="$1"
}
forge_ansible_prepare_antix
[[ "$prepared_command" == "getent group _ssh >/dev/null 2>&1 || groupadd --system _ssh" ]]

FORGE_LAYOUT=single
prepared_command=""
forge_ansible_prepare_antix
[[ -z "$prepared_command" ]]
mkdir -p "$tmpdir/rootfs/opt"
[[ "$(forge_tree_path "$tmpdir/rootfs" /opt/integration)" == "$tmpdir/rootfs/opt/integration" ]]
if forge_tree_path "$tmpdir/rootfs" /../../etc >/dev/null 2>&1; then exit 1; fi
[[ "$(forge_tree_path "$tmpdir/rootfs" /)" == "$tmpdir/rootfs" ]]


forge_in_chroot() {
  printf 'play #1 (local): p\tTAGS: []\n      TASK TAGS: [ai.local, plain]\n'
}
forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags 'ai.local'
if forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags 'ai-local' >/dev/null 2>&1; then
  exit 1
fi
if forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags 'ai.*' >/dev/null 2>&1; then
  exit 1
fi

# A manifest that names no tags has nothing to verify and must stay a no-op:
# the checks below make an unverifiable list fatal, and that must not turn
# every recipe without tags into a failed build.
forge_in_chroot() { echo "should not be reached" >&2; return 1; }
forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local tags
forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags

# Both of these used to warn and return 0, so a build whose tags could not be
# read looked exactly like one whose tags were all present. A skip_tags entry
# that matches nothing keeps whatever it was meant to leave out, which is the
# case the module's own comment calls the expensive one.
forge_in_chroot() { return 1; }
if forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags 'plain' >/dev/null 2>&1; then
  echo "built on an unreadable tag list" >&2
  exit 1
fi
if forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local tags 'plain' >/dev/null 2>&1; then
  echo "built on an unreadable tag list" >&2
  exit 1
fi

forge_in_chroot() { printf 'play #1 (local): p\tTAGS: []\n'; }
if forge_ansible_check_tags /opt/test /etc/skel site.yml inventory/local skip_tags 'plain' >/dev/null 2>&1; then
  echo "built against a playbook that defines no tags" >&2
  exit 1
fi

# The tag listing has to run with the same HOME as the galaxy install, or it
# cannot resolve the collections the playbook uses. This used to be checked by
# counting `export HOME=` in the source, which stayed at 2 while the listing
# ran without it and failed a real build. Check the command that is sent.
# The listing is read through $(...), a subshell, so the stub records the
# command in a file rather than a variable.
forge_in_chroot() {
  printf '%s' "$1" >"$tmpdir/listed_command"
  printf '      TASK TAGS: [plain]\n'
}
forge_ansible_check_tags /opt/test '/etc/skel dir' site.yml inventory/local tags 'plain'
listed_command=$(cat "$tmpdir/listed_command")
[[ "$listed_command" == 'export HOME=/etc/skel\ dir && cd /opt/test && ansible-playbook '* ]] || {
  echo "tag listing did not run with HOME=skel_home: $listed_command" >&2
  exit 1
}

# Galaxy, the tag listing and the playbook run must share one prefix. Run the
# whole provisioning step with the chroot stubbed and require every ansible
# command it sends to carry the same HOME.
cat >"$tmpdir/ansible-tags.yml" <<'YAML'
recipe: ansible-tags-regression
base:
  url: https://example.invalid/base.iso
output:
  name: ansible-test
  volume_id: ANSIBLE_TEST
ansible:
  repo: https://example.invalid/ansible-repo.git
  playbook: site.yml
  tags: [plain]
YAML
recipe_load "$tmpdir/ansible-tags.yml"
: >"$tmpdir/sent_commands"
forge_in_chroot() {
  printf '%s\0' "$1" >>"$tmpdir/sent_commands"
  case "$1" in
    *--list-tags*) printf '      TASK TAGS: [plain]\n' ;;
  esac
}
forge_in_chroot_soft() { forge_in_chroot "$1"; }
forge_ansible "$tmpdir/rootfs" >/dev/null
mapfile -d '' -t sent_commands <"$tmpdir/sent_commands"
ansible_commands=0
for c in "${sent_commands[@]}"; do
  [[ "$c" == *ansible-galaxy* || "$c" == *ansible-playbook* ]] || continue
  [[ "$c" == "command -v "* ]] && continue
  ansible_commands=$((ansible_commands + 1))
  [[ "$c" == 'export HOME=/etc/skel && '* ]] || {
    echo "ansible command without HOME=skel_home: $c" >&2
    exit 1
  }
done
[[ "$ansible_commands" == 3 ]] || {
  echo "expected galaxy, tag listing and playbook run, saw $ansible_commands ansible commands" >&2
  exit 1
}
