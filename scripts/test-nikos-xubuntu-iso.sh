#!/usr/bin/env bash
# Build and inspect the NikOS post-install image using the locally downloaded
# Xubuntu 24.04.4 ISO. This is deliberately separate from ./test: it needs
# root, roughly 25 GB of scratch space, and the downloaded base image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_ISO="${NIKOS_XUBUNTU_ISO:-$HOME/Downloads/iso_images/xubuntu-24.04.4-desktop-amd64.iso}"
OUTPUT_DIR="${NIKOS_ISO_OUTPUT_DIR:-$HOME/Downloads/iso_images}"
WORK_DIR="${NIKOS_ISO_WORK_DIR:-/var/tmp/isoforge-nikos-xubuntu-test}"
OUTPUT_ISO="$OUTPUT_DIR/nikos-xubuntu-24.04-amd64.iso"

usage() {
  cat <<EOF
Usage: $0 [--base-iso PATH] [--output DIR] [--work-dir DIR]

Builds recipes/nikos.yml from a downloaded Xubuntu 24.04.4 ISO, then verifies
that the output carries the NikOS post-install launcher. Defaults:
  base ISO: $BASE_ISO
  output:   $OUTPUT_ISO
  work:     $WORK_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-iso) BASE_ISO="${2:?--base-iso needs a path}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?--output needs a directory}"; shift 2; OUTPUT_ISO="$OUTPUT_DIR/nikos-xubuntu-24.04-amd64.iso" ;;
    --work-dir) WORK_DIR="${2:?--work-dir needs a directory}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$BASE_ISO" ]]; then
  echo "Xubuntu 24.04.4 has not been downloaded yet: $BASE_ISO" >&2
  echo "Download it first with iso-forge, then rerun this test." >&2
  exit 2
fi
if (( $(stat -c%s "$BASE_ISO") < 1000000000 )); then
  echo "Xubuntu base ISO is incomplete or unexpectedly small: $BASE_ISO" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
printf 'Using downloaded Xubuntu base: %s\n' "$BASE_ISO"
printf 'Writing NikOS installer ISO to: %s\n' "$OUTPUT_ISO"

sudo "$REPO_ROOT/forge" --recipe "$REPO_ROOT/recipes/nikos.yml" \
  --base-iso "$BASE_ISO" --work-dir "$WORK_DIR" --output "$OUTPUT_DIR"
sudo env TMPDIR="${TMPDIR:-/tmp}" "$REPO_ROOT/scripts/verify-nikos-iso.sh" "$OUTPUT_ISO"
