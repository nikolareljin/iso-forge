#!/usr/bin/env bash
# SCRIPT: build.sh
# DESCRIPTION: Run packaging/build sanity checks for this repository.
# USAGE: ./build [-h] [--full]
# PARAMETERS:
# -h                : show help
# --full            : run full package builds (deb/rpm/homebrew tarball)
# EXAMPLE: ./build --full
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    if [[ "$SCRIPT_SOURCE" != /* ]]; then
        SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
    fi
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF_CMD="./$(basename "$0")"

usage() {
    cat <<USAGE
Run packaging/build checks.

Usage: ${SELF_CMD} [-h] [--full]

Options:
  -h       Show help
  --full   Run full package builds using tools scripts
USAGE
}

run_full=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --full) run_full=true ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

cd "$ROOT_DIR"

required_files=(VERSION config.json inc/forge.sh recipes/example.yml recipes/nikos.yml scripts/verify-nikos-iso.sh assets/isoforge-logo.svg assets/ventoy/isoforge-background.png assets/ventoy/nikos-background.png tools/build-deb.sh tools/build-rpm.sh tools/build-brew-tarball.sh)
for f in "${required_files[@]}"; do
    [[ -e "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }
done

mapfile -t project_shell_files < <(find . \
    -path './.git' -prune -o \
    -path './scripts/script-helpers' -prune -o \
    -path './dist' -prune -o \
    -type f -name '*.sh' -print | sort)

if [[ "${#project_shell_files[@]}" -eq 0 ]]; then
    echo "No project shell files found for syntax checks." >&2
    exit 1
fi

echo "Running bash -n on project shell scripts..."
for f in "${project_shell_files[@]}"; do
    bash -n "$f"
done

if $run_full; then
    echo "Running full package builds..."
    ./tools/build-deb.sh
    ./tools/build-rpm.sh
    ./tools/build-brew-tarball.sh
else
    echo "Quick build checks complete. Use --full to run full package builds."
fi
