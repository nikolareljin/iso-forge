#!/usr/bin/env bash
# Fast checks for the NikOS post-install image recipe. The full artifact test
# is scripts/test-nikos-xubuntu-iso.sh and requires a downloaded Xubuntu ISO.
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
for m in yaml recipe fetch; do
  # shellcheck source=/dev/null
  source "$REPO_ROOT/inc/forge/$m.sh"
done

RECIPE="$REPO_ROOT/recipes/nikos.yml"
OVERLAY="$REPO_ROOT/recipes/overlay/nikos-installer"
LAUNCHER="$OVERLAY/usr/local/bin/nikos-installer"
PROFILE="$OVERLAY/usr/share/iso-forge/nikos-profiles/xubuntu-24.04.env"
DESKTOP="$OVERLAY/usr/share/applications/nikos-installer.desktop"

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

recipe_load "$RECIPE" >/dev/null 2>&1 || { echo "recipes/nikos.yml does not load" >&2; exit 1; }
ok "recipes/nikos.yml loads and validates"
check "it builds on a Xubuntu base" "$(recipe_get '.base.catalog_id')" "Xubuntu_24_04_4_desktop_amd64"
check "the output is named for the post-install image" "$(recipe_get '.output.name')" "nikos-xubuntu-24.04-amd64"
check "the volume id is the recipe's" "$(recipe_get '.output.volume_id')" "NIKOS_XUBUNTU_2404"
check "the recipe has one overlay" "$(recipe_get '.overlay | length')" "1"
check "the overlay is copied into the image root" "$(recipe_get '.overlay[0].dest')" "/"

if recipe_has '.ansible'; then bad "the recipe does not pre-provision NikOS with Ansible"; else ok "the recipe does not pre-provision NikOS with Ansible"; fi
if recipe_has '.packages'; then bad "the recipe does not install packages at build time"; else ok "the recipe does not install packages at build time"; fi
if [[ -x "$LAUNCHER" ]] && bash -n "$LAUNCHER"; then ok "the post-install launcher is executable and parses"; else bad "the post-install launcher is executable and parses"; fi
if [[ -f "$PROFILE" ]]; then ok "the Xubuntu 24.04 NikOS profile ships"; else bad "the Xubuntu 24.04 NikOS profile ships"; fi
if [[ -f "$DESKTOP" ]] && grep -qx 'Exec=nikos-installer' "$DESKTOP"; then ok "the desktop launcher starts nikos-installer"; else bad "the desktop launcher starts nikos-installer"; fi
if grep -q 'boot=casper' "$LAUNCHER"; then ok "the launcher refuses the live session"; else bad "the launcher refuses the live session"; fi
if grep -q 'NIKOS_REPO_REF="0.6.5"' "$PROFILE"; then ok "the profile pins the immutable NikOS release tag"; else bad "the profile pins the immutable NikOS release tag"; fi
if grep -q 'raw.githubusercontent.com/${github_repo}/${NIKOS_REPO_REF}/install.sh' "$LAUNCHER"; then ok "the launcher fetches the installer source at the selected ref"; else bad "the launcher fetches the installer source at the selected ref"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
