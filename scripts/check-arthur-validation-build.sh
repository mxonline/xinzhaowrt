#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:?PROJECT_ROOT is required}"
ARTHUR_CANDIDATE_SHA="${ARTHUR_CANDIDATE_SHA:?ARTHUR_CANDIDATE_SHA is required}"
EXPECTED_ARTHUR_CANDIDATE_SHA="${EXPECTED_ARTHUR_CANDIDATE_SHA:?EXPECTED_ARTHUR_CANDIDATE_SHA is required}"

[[ "${GITHUB_ACTIONS:-}" == true ]] || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo 'ERROR: validation builds are permitted only on GitHub-hosted Actions.' >&2
  exit 1
}
[[ "${VALIDATION_BUILD:-}" == true ]] || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo 'ERROR: VALIDATION_BUILD must be explicitly enabled.' >&2
  exit 1
}
[[ "${PUBLISH_CANDIDATE:-}" == false ]] || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo 'ERROR: candidate publication must be disabled for validation builds.' >&2
  exit 1
}
[[ "$ARTHUR_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ && "$ARTHUR_CANDIDATE_SHA" == "$EXPECTED_ARTHUR_CANDIDATE_SHA" ]] || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo 'ERROR: validation build candidate does not match the frozen expected SHA.' >&2
  exit 1
}
actual_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
[[ "$actual_sha" == "$ARTHUR_CANDIDATE_SHA" ]] || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo "ERROR: checked-out project SHA $actual_sha does not match the requested candidate." >&2
  exit 1
}

echo "ARTHUR_CANDIDATE_SHA=$ARTHUR_CANDIDATE_SHA"
echo 'VALIDATION_BUILD_ALLOWED=PASS'
