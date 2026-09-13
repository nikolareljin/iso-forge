#!/usr/bin/env bash
# Everything that changes the base system, in a fixed order:
#
#   keys and sources  ->  apt update  ->  remove  ->  install
#   ->  distrodeck export  ->  ansible  ->  overlay  ->  hooks
#
# Sources first because the installs may come from them. Removals before
# installs so a recipe can replace a package. Overlay after the package
# manager so a recipe's own files win over any package's version of them.
# Hooks last so they see the finished system.

# Resolve a consumer-provided absolute destination without allowing its host
# path to escape the image tree. This is used before any host-side copy.
forge_tree_path() {
  local tree="$1" dest="$2" tree_path candidate
  if [[ "$dest" != /* || "$dest" == *$'\n'* || "/${dest#/}/" == *"/../"* ]]; then
    log_error "Destination must be an absolute image path without traversal: $dest"
    return 2
  fi

  tree_path=$(realpath -m -- "$tree") || return 1
  candidate=$(realpath -m -- "$tree_path/${dest#/}") || return 1
  case "$candidate" in
    "$tree_path" | "$tree_path"/*) printf '%s\n' "$candidate" ;;
    *)
      log_error "Destination escapes the image tree: $dest"
      return 2
      ;;
  esac
}

# Starts with a lowercase letter or digit, then lowercase letters, digits and
# + - . _ . This is Debian's package-name grammar with underscore also allowed,
# which is looser than policy but matches what apt accepts in practice. An
# optional :arch qualifier is permitted for multiarch (libc6:i386), and an
# optional =version or /suite suffix because apt takes those too.
# Deliberately stricter than "anything without a shell metacharacter": these
# names reach apt running as root inside the image.
forge_valid_package_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9+._-]*(:[a-z0-9][a-z0-9-]*)?([=/][A-Za-z0-9+.:~_-]+)?$ ]]
}

forge_check_package_names() {
  local what="$1"; shift
  local bad=() p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    forge_valid_package_name "$p" || bad+=("$p")
  done
  if ((${#bad[@]})); then
    log_error "$what contains entries that are not package names: ${bad[*]}"
    log_error "Refusing to pass them to apt inside the image."
    return 2
  fi
}

# apt-get update is run at most once, but it has to run whenever sources
# changed even if no package is being installed: that update is what proves a
# new source line or key actually works, and a broken one should fail the build
# rather than the first machine installed from the image.
FORGE_APT_UPDATED=0

forge_apt_update() {
  ((FORGE_APT_UPDATED)) && return 0
  log_info "Refreshing package lists"
  forge_in_chroot "apt-get update -qq" || {
    log_error "apt-get update failed inside the image. A source or key added by"
    log_error "this recipe is likely wrong."
    return 1
  }
  FORGE_APT_UPDATED=1
}

forge_apt_keys() {
  local count
  count=$(recipe_get '.sources.keys // [] | length')
  ((count > 0)) || return 0

  log_info "Installing $count apt key(s)"
  local i url dest
  for ((i = 0; i < count; i++)); do
    url=$(recipe_get ".sources.keys[$i].url // \"\"")
    dest=$(recipe_get ".sources.keys[$i].dest // \"\"")
    if [[ -z "$url" || -z "$dest" ]]; then
      log_error "sources.keys[$i] needs both url and dest"
      return 2
    fi
    if [[ "$dest" != /* || "$dest" == "/" ]]; then
      log_error "sources.keys[$i].dest must be an absolute path inside the image: $dest"
      return 2
    fi
    local dest_host
    dest_host=$(forge_tree_path "$rootfs" "$dest") || return $?

    forge_in_chroot "mkdir -p \"\$(dirname $(forge_q "$dest"))\" && curl -fsSL $(forge_q "$url") -o $(forge_q "$dest") && chmod 0644 $(forge_q "$dest")" || {
      log_error "Could not install key $url"
      return 1
    }
  done
}

forge_apt_sources() {
  local -a ppas sources
  mapfile -t ppas < <(recipe_list '.sources.ppas')
  mapfile -t sources < <(recipe_list '.sources.apt')
  ppas+=("${FORGE_DD_PPAS[@]}")
  sources+=("${FORGE_DD_SOURCES[@]}")

  local p
  if ((${#ppas[@]})); then
    log_info "Adding ${#ppas[@]} PPA(s)"
    forge_in_chroot "command -v add-apt-repository >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y --no-install-recommends software-properties-common)" || return 1
    for p in "${ppas[@]}"; do
      [[ -n "$p" ]] || continue
      forge_in_chroot "add-apt-repository -y $(forge_q "$p")" || {
        log_error "Could not add $p"
        return 1
      }
    done
  fi

  if ((${#sources[@]})); then
    log_info "Adding ${#sources[@]} apt source line(s)"
    local list="/etc/apt/sources.list.d/isoforge.list"
    forge_in_chroot ": >$(forge_q "$list")" || return 1
    for p in "${sources[@]}"; do
      [[ -n "$p" ]] || continue
      forge_in_chroot "printf '%s\n' $(forge_q "$p") >>$(forge_q "$list")" || return 1
    done
  fi

  # Whatever was added, prove it resolves now.
  if ((${#ppas[@]} || ${#sources[@]})); then
    forge_apt_update || return 1
  fi
}

forge_apt_packages() {
  local -a install remove
  mapfile -t install < <(recipe_list '.packages.install')
  mapfile -t remove < <(recipe_list '.packages.remove')
  install+=("${FORGE_DD_APT[@]}")

  if ((${#install[@]} == 0 && ${#remove[@]} == 0)); then
    return 0
  fi

  forge_check_package_names "packages.install" "${install[@]}" || return $?
  forge_check_package_names "packages.remove" "${remove[@]}" || return $?

  forge_apt_update || return 1

  if ((${#remove[@]})); then
    log_info "Removing ${#remove[@]} package(s)"
    forge_in_chroot "apt-get purge -y $(forge_q "${remove[@]}")" || {
      log_error "Could not remove: ${remove[*]}"
      return 1
    }
  fi

  if ((${#install[@]})); then
    log_info "Installing ${#install[@]} package(s)"
    forge_in_chroot "apt-get install -y --no-install-recommends $(forge_q "${install[@]}")" || {
      log_error "Could not install: ${install[*]}"
      return 1
    }
  fi

  forge_in_chroot_soft "apt-get autoremove -y"
}

forge_flatpaks() {
  local -a apps
  mapfile -t apps < <(recipe_list '.flatpak')
  apps+=("${FORGE_DD_FLATPAK[@]}")
  ((${#apps[@]})) || return 0

  log_info "Installing ${#apps[@]} flatpak(s)"
  forge_in_chroot "command -v flatpak >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y --no-install-recommends flatpak)" || return 1

  local line remote app
  for line in "${apps[@]}"; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"remote="* ]]; then
      remote=$(forge_dd_flatpak_fields "$line" remote)
      app=$(forge_dd_flatpak_fields "$line" app)
    else
      remote="flathub"
      app="$line"
    fi
    [[ -n "$app" ]] || continue
    forge_in_chroot "flatpak remote-add --system --if-not-exists $(forge_q "$remote") https://dl.flathub.org/repo/flathub.flatpakrepo" || return 1
    # --system so the app lands in the image rather than a user home that does
    # not exist yet.
    forge_in_chroot_soft "flatpak install --system -y $(forge_q "$remote" "$app")"
  done
}

forge_overlay() {
  local recipe_dir="$1" rootfs="$2"
  local count
  count=$(recipe_get '.overlay // [] | length')
  ((count > 0)) || return 0

  log_info "Copying $count overlay entries"
  local i src dest abs_src
  for ((i = 0; i < count; i++)); do
    src=$(recipe_get ".overlay[$i].src // \"\"")
    dest=$(recipe_get ".overlay[$i].dest // \"\"")
    if [[ -z "$src" || -z "$dest" ]]; then
      log_error "overlay[$i] needs both src and dest"
      return 2
    fi
    if [[ "$dest" != /* ]]; then
      log_error "overlay[$i].dest must be an absolute path inside the image: $dest"
      return 2
    fi
    local dest_host
    dest_host=$(forge_tree_path "$rootfs" "$dest") || return $?


    abs_src="$src"
    [[ "$abs_src" == /* ]] || abs_src="$recipe_dir/$src"
    if [[ ! -e "$abs_src" ]]; then
      log_error "overlay[$i].src does not exist: $abs_src"
      return 2
    fi

    mkdir -p "$(dirname "$dest_host")"
    # A trailing slash on the source copies its contents; without one it copies
    # the directory itself. Normalise to "contents of" for directories.
    if [[ -d "$abs_src" ]]; then
      mkdir -p "$dest_host"
      rsync -a "$abs_src/" "$dest_host/" || return 1
    else
      rsync -a "$abs_src" "$dest_host" || return 1
    fi
  done
}

# Files for the live image tree (boot assets, installer metadata, and similar)
# are applied after the root filesystem has been repacked and before checksums
# are regenerated. Their destination is still constrained to the extracted ISO.
forge_live_overlay() {
  local recipe_dir="$1" iso_dir="$2"
  local count
  count=$(recipe_get '.live_overlay // [] | length')
  ((count > 0)) || return 0

  log_info "Copying $count live-image overlay entries"
  local i src dest abs_src dest_host
  for ((i = 0; i < count; i++)); do
    src=$(recipe_get ".live_overlay[$i].src // \"\"")
    dest=$(recipe_get ".live_overlay[$i].dest // \"\"")
    if [[ -z "$src" || -z "$dest" ]]; then
      log_error "live_overlay[$i] needs both src and dest"
      return 2
    fi
    dest_host=$(forge_tree_path "$iso_dir" "$dest") || return $?

    abs_src="$src"
    [[ "$abs_src" == /* ]] || abs_src="$recipe_dir/$src"
    if [[ ! -e "$abs_src" ]]; then
      log_error "live_overlay[$i].src does not exist: $abs_src"
      return 2
    fi

    mkdir -p "$(dirname "$dest_host")"
    if [[ -d "$abs_src" ]]; then
      mkdir -p "$dest_host"
      rsync -a "$abs_src/" "$dest_host/" || return 1
    else
      rsync -a "$abs_src" "$dest_host" || return 1
    fi
  done
}

forge_hooks() {
  local phase="${3:-chroot}"
  local recipe_dir="$1" rootfs="$2"
  local -a hooks
  mapfile -t hooks < <(recipe_list ".hooks.$phase")
  ((${#hooks[@]})) || return 0

  log_info "Running ${#hooks[@]} chroot hook(s)"
  local h abs staged
  for h in "${hooks[@]}"; do
    [[ -n "$h" ]] || continue
    abs="$h"
    [[ "$abs" == /* ]] || abs="$recipe_dir/$h"
    if [[ ! -f "$abs" ]]; then
      log_error "Hook not found: $abs"
      return 2
    fi
    staged="/tmp/isoforge-hook-$(basename "$abs")"
    install -m 0755 "$abs" "$rootfs$staged" || return 1
    log_info "  hook: $(basename "$abs")"
    if ! forge_in_chroot "$(forge_q "$staged")"; then
      log_error "Hook failed: $abs"
      rm -f "$rootfs$staged"
      return 1
    fi
    rm -f "$rootfs$staged"
  done
}

forge_customize() {
  local recipe_dir="$1" rootfs="$2"

  forge_apt_keys           || return $?
  forge_apt_sources        || return $?
  forge_apt_packages       || return $?
  forge_flatpaks           || return $?
  forge_hooks   "$recipe_dir" "$rootfs" bootstrap || return $?
  forge_ansible "$rootfs" "$recipe_dir" || return $?
  forge_overlay "$recipe_dir" "$rootfs" || return $?
  forge_hooks   "$recipe_dir" "$rootfs" || return $?
}
