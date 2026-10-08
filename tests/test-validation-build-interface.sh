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

# A validation/evidence commit may follow the frozen firmware source. Permit
# only explicit control-plane/evidence paths while keeping firmware inputs fixed.
mkdir -p "$PROJECT/production" "$PROJECT/.github/workflows" "$PROJECT/scripts"
printf '{"status":"test-only"}\n' > "$PROJECT/production/operator-intent.json"
printf 'workflow control\n' > "$PROJECT/.github/workflows/arthur-control-plane.yml"
printf '# resume control\n' > "$PROJECT/scripts/arthur-firmware-resume.ps1"
git -C "$PROJECT" add production/operator-intent.json .github/workflows/arthur-control-plane.yml scripts/arthur-firmware-resume.ps1
git -C "$PROJECT" commit -qm 'control: add validation metadata'
validation_success="$(GITHUB_ACTIONS=true VALIDATION_BUILD=true PUBLISH_CANDIDATE=false \
  ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" EXPECTED_ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" \
  PROJECT_ROOT="$PROJECT" bash "$GATE")"
grep -Fqx 'VALIDATION_BUILD_ALLOWED=PASS' <<<"$validation_success"

mkdir -p "$PROJECT/config"
printf 'CONFIG_PACKAGE_unexpected=y\n' > "$PROJECT/config/arthur.config"
git -C "$PROJECT" add config/arthur.config
git -C "$PROJECT" commit -qm 'firmware: change product payload'
if GITHUB_ACTIONS=true VALIDATION_BUILD=true PUBLISH_CANDIDATE=false \
  ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" EXPECTED_ARTHUR_CANDIDATE_SHA="$CANDIDATE_SHA" \
  PROJECT_ROOT="$PROJECT" bash "$GATE" >"$TMP/payload-change.out" 2>&1; then
  echo 'FAIL: validation build accepted a firmware payload change after the frozen source' >&2
  exit 1
fi

build_source="$ROOT/scripts/build.sh"
grep -Fq 'check-openclash-adh-prebuild-live.py' "$build_source" || {
  echo 'FAIL: build entrypoint must call the canonical prebuild evidence checker' >&2
  exit 1
}
grep -Fq 'PREBUILD_VALIDATION_SHA' "$build_source" || {
  echo 'FAIL: build entrypoint must validate evidence at the control/evidence commit while preserving the firmware source SHA' >&2
  exit 1
}

echo 'VALIDATION_BUILD_INTERFACE_TEST=PASS'
