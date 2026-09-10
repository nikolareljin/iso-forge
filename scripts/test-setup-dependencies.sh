#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

helpers_dir="$tmpdir/helpers"
mkdir -p "$helpers_dir"
cat >"$helpers_dir/helpers.sh" <<'EOF'
#!/usr/bin/env bash
shlib_import() { :; }
print_info() { :; }
print_success() { :; }
install_dependencies() { printf '%s\n' "$*" >"$SETUP_PACKAGES_FILE"; }
EOF

packages_file="$tmpdir/packages"
SETUP_PACKAGES_FILE="$packages_file" SCRIPT_HELPERS_DIR="$helpers_dir" \
  bash "$ROOT_DIR/inc/setup.sh"

packages="$(cat "$packages_file")"
[[ "$packages" == *"exfatprogs"* ]]
[[ " $packages " == *" xz-utils "* ]]
[[ " $packages " != *" xz xz-utils "* ]]
[[ "$packages" != *"exfat-utils"* ]]
