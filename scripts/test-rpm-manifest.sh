#!/usr/bin/env bash
# Verify that RPM packaging accepts man pages after RPM's compression hook.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -Fqx '/usr/share/man/man1/isoforge.1*' "$ROOT_DIR/packaging/isoforge.spec"
