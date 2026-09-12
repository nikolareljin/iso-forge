#!/usr/bin/env bash
# Entering and leaving the base system safely.
#
# Every mount made here is recorded so teardown can release them in reverse
# even when a stage fails. A build that dies with /proc still bound inside the
# work directory will take the host's next `rm -rf` with it.

FORGE_CHROOT_MOUNTS=()
FORGE_CHROOT_DIR=""
FORGE_POLICY_RC=""
FORGE_RESOLV_BACKUP=""

forge_chroot_enter() {
  local rootfs="$1"
  FORGE_CHROOT_DIR="$rootfs"

  local m
  for m in /dev /dev/pts /proc /sys /run; do
    mkdir -p "$rootfs$m"
    if ! mount --rbind "$m" "$rootfs$m"; then
      log_error "Could not bind $m into the chroot"
      return 1
    fi
    mount --make-rslave "$rootfs$m" 2>/dev/null || true
    FORGE_CHROOT_MOUNTS+=("$rootfs$m")
  done

  # The image ships a resolv.conf pointing at the live session's resolver.
  # Keep it and restore it, or the built system inherits the build host's.
  #
  # On Ubuntu that file is a symlink into /run/systemd/resolve, and /run is
  # bind-mounted from the host by the loop above. Writing through the symlink
  # would therefore land on the *host's* resolver configuration, so the link is
  # removed first and replaced with a plain file. cp -a copies the link itself
  # rather than its target, so the backup restores what was there.
  if [[ -e "$rootfs/etc/resolv.conf" || -L "$rootfs/etc/resolv.conf" ]]; then
    FORGE_RESOLV_BACKUP="$rootfs/etc/resolv.conf.isoforge-orig"
    cp -a "$rootfs/etc/resolv.conf" "$FORGE_RESOLV_BACKUP" 2>/dev/null || FORGE_RESOLV_BACKUP=""
  fi
  rm -f "$rootfs/etc/resolv.conf"
  cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true

  # Without this, installing a package starts its daemon on the build host's
  # kernel, inside a filesystem that is about to be squashed.
  FORGE_POLICY_RC="$rootfs/usr/sbin/policy-rc.d"
  mkdir -p "$rootfs/usr/sbin"
  printf '#!/bin/sh\nexit 101\n' >"$FORGE_POLICY_RC"
  chmod 0755 "$FORGE_POLICY_RC"
}

forge_chroot_unmount_mounts() {
  local i
  for ((i = ${#FORGE_CHROOT_MOUNTS[@]} - 1; i >= 0; i--)); do
    umount -R "${FORGE_CHROOT_MOUNTS[i]}" 2>/dev/null \
      || umount -Rl "${FORGE_CHROOT_MOUNTS[i]}" 2>/dev/null \
      || log_warn "Could not unmount ${FORGE_CHROOT_MOUNTS[i]}"
  done
  FORGE_CHROOT_MOUNTS=()
}


forge_chroot_leave() {
  local rootfs="${FORGE_CHROOT_DIR:-}"

  # Normally already done by forge_chroot_cleanup, before the repack. Repeated
  # here for the path where a build failed before reaching it.
  forge_chroot_unscaffold

  forge_chroot_unmount_mounts
  FORGE_CHROOT_DIR=""
}

# Recipes and distrodeck exports are data, not code. Every value that reaches
# the chroot shell goes through this first, so a package name carrying shell
# metacharacters cannot become a command running as root against the host's
# bound /dev.
forge_q() {
  local out="" a
  for a in "$@"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

# `env -i` rather than `env`: without it the build host's environment reaches
# the chroot, and the image then depends on who built it. A real build failed
# exactly this way, with NVM_DIR=/home/runner/.nvm inherited from a CI runner
# pointing an installer at a directory that does not exist inside the image.
# The same leak would carry SUDO_*, GITHUB_*, proxy settings and a host HOME.
#
# Everything the chroot is allowed to see is listed here.
forge_in_chroot() {
  chroot "$FORGE_CHROOT_DIR" /usr/bin/env -i \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    USER=root \
    LOGNAME=root \
    SHELL=/bin/bash \
    TERM="${TERM:-dumb}" \
    /bin/bash -c "$1"
}

# Same as forge_in_chroot but the caller has already decided a failure is not
# fatal, so the build continues and says what did not work.
forge_in_chroot_soft() {
  if ! forge_in_chroot "$1"; then
    log_warn "Command failed inside the chroot, continuing: $1"
    return 0
  fi
}

# Everything that would otherwise make the built system look like the machine
# that built it, or carry build-time noise into every install.
forge_chroot_cleanup() {
  log_info "Cleaning the root filesystem"
  forge_in_chroot_soft "apt-get clean"
  forge_in_chroot_soft "rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb"
  forge_in_chroot_soft "rm -rf /tmp/* /var/tmp/*"
  forge_in_chroot_soft "find /var/log -type f -exec truncate -s 0 {} +"
  forge_in_chroot_soft "rm -f /root/.bash_history /root/.wget-hsts"

  # A non-empty machine-id is copied to every installed system, which makes
  # systemd and DHCP treat them all as the same host.
  forge_in_chroot_soft ": >/etc/machine-id"
  forge_in_chroot_soft "rm -f /var/lib/dbus/machine-id"

  # The build's own scaffolding has to come out here, not in forge_chroot_leave.
  # The root filesystem is squashed between the two, so anything still in place
  # now ships inside the image: a policy-rc.d returning 101 would refuse to
  # start services on the installed machine, and the build host's resolv.conf
  # would be handed to every user of the image.
  forge_chroot_unscaffold
}

# Undo what forge_chroot_enter put in place. Idempotent, because it runs before
# the repack and again on the way out in case a build failed before reaching it.
forge_chroot_unscaffold() {
  local rootfs="${FORGE_CHROOT_DIR:-}"
  [[ -n "$rootfs" ]] || return 0

  if [[ -n "$FORGE_POLICY_RC" && -f "$FORGE_POLICY_RC" ]]; then
    rm -f "$FORGE_POLICY_RC"
    FORGE_POLICY_RC=""
  fi

  if [[ -n "$FORGE_RESOLV_BACKUP" ]] && [[ -e "$FORGE_RESOLV_BACKUP" || -L "$FORGE_RESOLV_BACKUP" ]]; then
    # Remove first: the file being restored may be a symlink, and mv onto an
    # existing symlink would follow it.
    rm -f "$rootfs/etc/resolv.conf"
    mv -f "$FORGE_RESOLV_BACKUP" "$rootfs/etc/resolv.conf"
    FORGE_RESOLV_BACKUP=""
  fi
}
