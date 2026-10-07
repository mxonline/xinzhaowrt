#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-arthur-validation-build.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Validation Build Contract Test'
git -C "$PROJECT" config user.email 'validation-build-test@example.invalid'
printf 'fixture\n' > "$PROJECT/source.txt"
git -C "$PROJECT" add source.txt
git -C "$PROJECT" commit -qm 'frozen candidate fixture'
CANDIDATE_SHA="$(git -C "$PROJECT" rev-parse HEAD)"

success="$(GITHUB_ACTIONS=true VALIDATION_BUILD=true PUBLISH_CANDIDATE=false \
  ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" EXPECTED_ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" \
  PROJECT_ROOT="$PROJECT" bash "$GATE")"
grep -Fqx 'VALIDATION_BUILD_ALLOWED=PASS' <<<"$success"

if GITHUB_ACTIONS=true VALIDATION_BUILD=true PUBLISH_CANDIDATE=true \
  ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" EXPECTED_ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" \
  PROJECT_ROOT="$PROJECT" bash "$GATE" \
  >"$TMP/release-on.out" 2>&1; then
  echo 'FAIL: validation build accepted candidate publication' >&2
  exit 1
fi

if GITHUB_ACTIONS=true VALIDATION_BUILD=true PUBLISH_CANDIDATE=false \
  ARTHUR_CANDIDATE_SHA="0000000000000000000000000000000000000000" \
  EXPECTED_ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" PROJECT_ROOT="$PROJECT" \
  bash "$GATE" >"$TMP/wrong-source.out" 2>&1; then
  echo 'FAIL: validation build accepted a different checked-out source' >&2
  exit 1
fi

echo 'VALIDATION_BUILD_INTERFACE_TEST=PASS'
