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

# The creator reads a recipe the way the builder does: base, then a deep-merged
# foo.local.yml on top (inc/forge/recipe.sh recipe_load). Reading only the base
# layer let it hide a valid ISO, offer one the build rejects, and name an
# output file that was never written.
eval "$(sed -n '/^iso_creator_recipe_json()/,/^}/p' "$creator")"
cat >"$tmpdir/r.yml" <<'YML'
recipe: merged
base: {catalog_id: Xubuntu_24_04_4_desktop_amd64}
compatibility:
  base_filename_patterns: ['^xubuntu-.*\.iso$']
output: {name: base-name}
YML
[[ "$(iso_creator_recipe_json "$tmpdir/r.yml" | jq -r '.output.name')" == "base-name" ]]
cat >"$tmpdir/r.local.yml" <<'YML'
output: {name: overridden-name}
compatibility:
  base_filename_patterns: ['^kubuntu-.*\.iso$']
YML
[[ "$(iso_creator_recipe_json "$tmpdir/r.yml" | jq -r '.output.name')" == "overridden-name" ]]
[[ "$(iso_creator_recipe_json "$tmpdir/r.yml" | jq -r '.compatibility.base_filename_patterns[0]')" == '^kubuntu-.*\.iso$' ]]
# keys the local layer does not mention survive the merge
[[ "$(iso_creator_recipe_json "$tmpdir/r.yml" | jq -r '.base.catalog_id')" == "Xubuntu_24_04_4_desktop_amd64" ]]

# An override layer is not a recipe on its own, so it must not appear in the menu.
grep -Fq "! -name '*.local.yml' ! -name '*.local.yaml'" "$creator"
