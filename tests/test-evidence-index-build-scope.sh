#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scope="$(printf '%s\n' 'production/evidence/arthur-adh-cn-aaaaaaa-20260908/index.json' | bash scripts/classify-build-scope.sh)"
[[ "$scope" == 'FAST_GATE' ]] || {
  echo "TEST_FAIL: evidence-index-only change must be FAST_GATE, got $scope" >&2
  exit 1
}

echo 'ARTHUR_EVIDENCE_BUILD_SCOPE=PASS'
