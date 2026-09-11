#!/usr/bin/env bash
# Run a consumer-declared Ansible playbook inside the image being built.
# Per-user defaults are written to the declared skeleton home, so accounts
# created by the installer inherit them without relying on a host session.
forge_ansible_available() {
  recipe_has '.ansible'
}

forge_ansible() {
  local rootfs="$1" recipe_dir="${2:-}"
  forge_ansible_available || return 0

  local repo ref playbook dest skel_home source
  repo=$(recipe_get '.ansible.repo')
  source=$(recipe_get '.ansible.source // "repo"')
  ref=$(recipe_get '.ansible.ref // ""')
  playbook=$(recipe_get '.ansible.playbook')
  dest=$(recipe_get '.ansible.dest // "/opt/isoforge/integration"')
  skel_home=$(recipe_get '.ansible.skel_home // "/etc/skel"')

  log_info "Provisioning with the selected Ansible integration"

  forge_in_chroot "command -v ansible-playbook >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y --no-install-recommends ansible-core git ca-certificates)" || {
    log_error "Could not install ansible-core inside the image"
    return 1
  }

  if [[ "$source" == "integration" ]]; then
    [[ -n "$recipe_dir" ]] || { log_error "Integration source directory is missing"; return 2; }
    forge_in_chroot "rm -rf $(forge_q "$dest") && mkdir -p $(forge_q "$dest")" || return 1
    rsync -a --delete --exclude .git "$recipe_dir/" "$rootfs$dest/" || return 1
  else
    local clone="rm -rf $(forge_q "$dest") && git clone --depth 1"
    [[ -n "$ref" ]] && clone+=" --branch $(forge_q "$ref")"
    clone+=" --recurse-submodules $(forge_q "$repo" "$dest")"
    forge_in_chroot "$clone" || {
      log_error "Could not clone the requested Ansible source"
      return 1
    }
  fi

  # Requirements are optional; a playbook with no collections still works.
  # HOME is set here for the same reason it is set for the run below: galaxy
  # installs collections under $HOME/.ansible and ansible-playbook looks for
  # them in the same place, so installing with one HOME and running with
  # another loses them. That failed a real build with "couldn't resolve
  # module/action 'community.general.timezone'".
  forge_in_chroot_soft "export HOME=$(forge_q "$skel_home") && cd $(forge_q "$dest") && [ -f requirements.yml ] && ansible-galaxy collection install -r requirements.yml || true"

  local -a args=()

  # One JSON blob rather than a series of key=value pairs. ansible parses
  # `-e key=value` as a string no matter what it looks like, so a recipe could
  # not pass a list or a mapping: `-e consumer_extensions=[]` sets the
  # string "[]", and a role that concatenates it with another list then fails
  # on a string. JSON keeps the recipe's types intact.
  local vars_json
  vars_json=$(jq -c --arg home "$skel_home" \
    '{isoforge_target_home: $home} * (.ansible.extra_vars // {})' <<<"$RECIPE_JSON")
  args+=(-e "$vars_json")

  local -a tags skips
  mapfile -t tags < <(recipe_list '.ansible.tags')
  mapfile -t skips < <(recipe_list '.ansible.skip_tags')
  ((${#tags[@]}))  && args+=(--tags "$(IFS=,; echo "${tags[*]}")")
  ((${#skips[@]})) && args+=(--skip-tags "$(IFS=,; echo "${skips[*]}")")

  local inventory
  inventory=$(recipe_get '.ansible.inventory // "inventory/local"')

  forge_ansible_check_tags "$dest" "$playbook" "$inventory" tags "${tags[@]}" || return $?
  forge_ansible_check_tags "$dest" "$playbook" "$inventory" skip_tags "${skips[@]}" || return $?

  # HOME has to agree with skel_home for the whole run. Roles install per-user
  # tooling by shelling out to installers that honour $HOME, while their
  # `creates:` guards and later tasks look under the playbook's own home
  # variable. With the two disagreeing, an installer writes to one place and
  # the next task reads the other: a consumer tool-install step failed exactly that way,
  # installing into /root/.nvm and then failing to source /etc/skel/.nvm/nvm.sh.
  #
  # Pointing HOME at /etc/skel is also what the result should be. Anything a
  # role leaves in the user's home is then copied into every account the
  # installer creates, which is the entire reason skel_home exists.
  #
  # --connection=local because the chroot is the target; ansible must not try
  # to ssh anywhere.
  local cmd="export HOME=$(forge_q "$skel_home") && cd $(forge_q "$dest") && ansible-playbook $(forge_q "$playbook") -i $(forge_q "$inventory") --connection=local"
  local a
  for a in "${args[@]}"; do
    cmd+=" $(printf '%q' "$a")"
  done

  log_info "  $cmd"
  if ! forge_in_chroot "$cmd"; then
    log_error "The playbook failed. Tasks that need a running desktop session cannot"
    log_error "run at build time; list them under ansible.skip_tags in the recipe."
    return 1
  fi
}

# A tag that names nothing is silently ignored by ansible-playbook, and the
# failure mode is asymmetric: a bad `tags` entry runs less than intended, while
# a bad `skip_tags` entry runs *more* than intended. For an image build that
# second case is the expensive one, so both are checked and both are fatal.
#
# Roles listed in a playbook without a `tags:` key cannot be selected or
# skipped by name at all, which is exactly the trap this catches.
forge_ansible_check_tags() {
  local dest="$1" playbook="$2" inventory="$3" field="$4"
  shift 4
  local -a wanted=("$@")
  ((${#wanted[@]})) || return 0

  local listing
  if ! listing=$(forge_in_chroot "cd $(forge_q "$dest") && ansible-playbook $(forge_q "$playbook") -i $(forge_q "$inventory") --connection=local --list-tags 2>/dev/null"); then
    log_warn "Could not list the playbook's tags; ansible.$field is not being checked."
    return 0
  fi

  # ansible prints "TASK TAGS: [a, b, c]", sometimes more than once.
  local available
  available=$(printf '%s\n' "$listing" \
    | sed -n 's/.*TASK TAGS: *\[\(.*\)\].*/\1/p' \
    | tr ',' '\n' | tr -d ' ' | sort -u)

  if [[ -z "$available" ]]; then
    log_warn "The playbook reported no tags; ansible.$field is not being checked."
    return 0
  fi

  local missing=() t
  for t in "${wanted[@]}"; do
    [[ -n "$t" ]] || continue
    # -F because a tag is a literal name. Without it a tag carrying a regex
    # metacharacter would match something it does not name, or fail to match
    # itself, and the guard would report the opposite of the truth.
    grep -qxF -- "$t" <<<"$available" || missing+=("$t")
  done

  if ((${#missing[@]})); then
    log_error "ansible.$field names tags this playbook does not define: ${missing[*]}"
    log_error "Available tags: $(paste -sd' ' - <<<"$available")"
    if [[ "$field" == "skip_tags" ]]; then
      log_error "A skip that matches nothing does not reduce the build, it silently"
      log_error "includes whatever you meant to leave out. Refusing to continue."
    fi
    return 2
  fi
}
