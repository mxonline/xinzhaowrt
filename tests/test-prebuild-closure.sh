#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/prebuild-closure.sh"
grep -Fq "PREBUILD_CLOSURE=PASS" "$SCRIPT"
grep -Fq "FULL_BUILD_ALLOWED=true" "$SCRIPT"
grep -Fq "PACKAGE_ONLY_TESTS=PASS" "$SCRIPT"
grep -Fq "NO_UNRESOLVED_CORE_WRITER=PASS" "$SCRIPT"
echo 'PREBUILD_CLOSURE_CONTRACT=PASS'
