#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/release-candidate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Build 29 packages an Arthur sysupgrade image under the project display name,
# not the upstream jdcloud_re-ss-01 filename.  Candidate publication must use
# the packaged sysupgrade asset while retaining a profile identity check.
rg -Fq -- "-name '*sysupgrade.bin'" "$SCRIPT" || fail 'candidate release does not discover packaged sysupgrade artifacts'
rg -Fq 'profiles.json' "$SCRIPT" || fail 'candidate release does not verify the Arthur profile metadata'
rg -Fq 'jdcloud_re-ss-01' "$SCRIPT" || fail 'candidate release does not bind metadata verification to Arthur'

echo 'PASS: Candidate release reconciles Build 29 artifact naming with Arthur profile metadata.'