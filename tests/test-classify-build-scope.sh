#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/scripts/classify-build-scope.sh"

run_case() {
  local expected="$1"
  shift
  local actual
  actual="$(printf '%s\n' "$@" | bash "$CLASSIFIER")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: expected %s, got %s for:\n' "$expected" "$actual" >&2
    printf '  %s\n' "$@" >&2
    exit 1
  fi
}

run_case DOC_ONLY \
  README.md \
  knowledge/PROJECT-STATE.md \
  docs/notes.md

run_case FAST_GATE \
  .github/workflows/arthur-update-v3.yml

run_case FAST_GATE \
  scripts/analyze-error.sh \
  scripts/verify-project.sh \
  tests/test-classify-build-scope.sh \
  production/v4-state.json

# v4 explicit ImageBuilder lane. Only explicitly migrated v4 paths may use it.
run_case IMAGEBUILDER \
  production/v4/imagebuilder-request.json \
  v4/imagebuilder/packages.txt \
  v4/imagebuilder/files/etc/config/xinzhao \
  scripts/v4-imagebuilder-build.sh

# v4 explicit SDK lane. User-space package builds outrank ImageBuilder assembly.
run_case SDK_BUILD \
  production/v4/sdk-request.json \
  v4/sdk/packages/luci-app-example/Makefile \
  scripts/v4-sdk-build.sh

run_case FULL_BUILD \
  config/arthur.config

run_case FULL_BUILD \
  config/required-plugins.txt \
  files/etc/config/xinzhao

run_case FULL_BUILD \
  patches/901-arthur-upload-oom.patch \
  scripts/build.sh

run_case FULL_BUILD \
  production/v4/full-request.json \
  v4/full/kernel-change.marker

run_case FULL_BUILD \
  some/new-unknown-path.txt

# Highest-risk scope wins for mixed changes.
run_case IMAGEBUILDER \
  README.md \
  .github/workflows/arthur-update-v3.yml \
  v4/imagebuilder/packages.txt

run_case SDK_BUILD \
  README.md \
  v4/imagebuilder/packages.txt \
  v4/sdk/packages/luci-app-example/Makefile

run_case FULL_BUILD \
  README.md \
  v4/imagebuilder/packages.txt \
  v4/sdk/packages/luci-app-example/Makefile \
  config/arthur.config

echo 'PASS: build scope classifier behavior is correct.'
