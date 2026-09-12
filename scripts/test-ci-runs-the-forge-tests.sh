#!/usr/bin/env bash
# Every forge test scripts/test.sh runs is also run by the pull request gate.
#
# The two lists were maintained separately and drifted: scripts/test.sh grew
# test-forge-integration.sh and test-forge-ansible.sh, .github/workflows/pr.yml
# named four scripts and neither of those. A pull request adding a feature and
# its only regression test was therefore green with that test never executed --
# the test existed, ran locally, and proved nothing about the branch.
#
# Comparing the two lists is cheap; remembering to edit both is what failed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

suite=$(grep -oE './scripts/test-forge-[a-z0-9-]+\.sh' scripts/test.sh | sort -u)
gate=$(grep -oE './scripts/test-forge-[a-z0-9-]+\.sh' .github/workflows/pr.yml | sort -u)

# A list this reads as empty would make every comparison below trivially pass,
# which is the failure this test exists to catch. Refuse to be that gate.
[[ -n "$suite" ]] || { echo "found no forge tests in scripts/test.sh" >&2; exit 1; }
[[ -n "$gate" ]]  || { echo "found no forge tests in .github/workflows/pr.yml" >&2; exit 1; }

missing=$(comm -23 <(printf '%s\n' "$suite") <(printf '%s\n' "$gate"))
if [[ -n "$missing" ]]; then
  echo "forge tests run locally but not by the pull request gate:" >&2
  while IFS= read -r t; do echo "  $t" >&2; done <<<"$missing"
  echo "add them to test_command in .github/workflows/pr.yml" >&2
  exit 1
fi

# Named in the gate and nowhere in the suite: usually a rename that updated one
# file, and it fails the gate at push time rather than here.
unknown=$(comm -13 <(printf '%s\n' "$suite") <(printf '%s\n' "$gate"))
if [[ -n "$unknown" ]]; then
  echo "the pull request gate names forge tests scripts/test.sh does not run:" >&2
  while IFS= read -r t; do echo "  $t" >&2; done <<<"$unknown"
  exit 1
fi

echo "CI runs every forge test the suite does."
