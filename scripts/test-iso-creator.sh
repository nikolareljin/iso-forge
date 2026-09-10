#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

base_iso="$tmpdir/xubuntu-24.04.4-desktop-amd64.iso"
: >"$base_iso"
output="$("$ROOT_DIR"/forge --recipe "$ROOT_DIR/recipes/example.yml" --base-iso "$base_iso" --dry-run 2>&1)"
[[ "$output" == *"$base_iso (local override)"* ]]

# The interactive creator must load the destination in its parent shell: both
# selectors run in command substitutions, which otherwise discard their state.
creator="$ROOT_DIR/inc/isoforge.sh"
grep -A9 '^main_menu()' "$creator" | grep -qx '  load_config'
grep -q 'iso_creator_output_path' "$creator"
grep -q 'recipe=$(select_iso_creator_recipe)' "$creator"
grep -Fq 'base_iso=$(select_iso_creator_base "$recipe")' "$creator"
grep -q 'iso_creator_base_matches_recipe' "$creator"
grep -Fq 'grep -Eq -- "$pattern"' "$creator"
grep -Fq -- '--base-iso "$base_iso" --config "$CONFIG_FILE" --output "$DOWNLOAD_DIR"' "$creator"
grep -Fq "New ISO created:\\n\$created_iso" "$creator"
