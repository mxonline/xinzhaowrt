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

run_contract_case() {
  local expected_class="$1"
  local expected_invalidation="$2"
  local expected_build="$3"
  shift 3
  local actual
  actual="$(printf '%s\n' "$@" | bash "$CLASSIFIER" --release-contract)"
  grep -Fxq "RELEASE_IMPACT_CLASS=$expected_class" <<<"$actual" || {
    printf 'FAIL: expected RELEASE_IMPACT_CLASS=%s, got:\n%s\n' "$expected_class" "$actual" >&2
    exit 1
  }
  grep -Fxq "MINIMUM_INVALIDATION=$expected_invalidation" <<<"$actual" || {
    printf 'FAIL: expected MINIMUM_INVALIDATION=%s, got:\n%s\n' "$expected_invalidation" "$actual" >&2
    exit 1
  }
  grep -Fxq "FIRMWARE_BUILD_REQUIRED=$expected_build" <<<"$actual" || {
    printf 'FAIL: expected FIRMWARE_BUILD_REQUIRED=%s, got:\n%s\n' "$expected_build" "$actual" >&2
    exit 1
  }
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

run_case FAST_GATE \
  production/known-good.json \
  production/arthur-known-good-v1.json \
  scripts/baseline-integrity-gate.sh

run_case FAST_GATE \
  scripts/production-agent.ps1 \
  scripts/install-production-agent.ps1 \
  scripts/start-production-agent.ps1 \
  scripts/production-agent-status.ps1 \
  scripts/ci-controller-v3.ps1 \
  scripts/bridge-runtime-status.ps1 \
  scripts/recover-existing-bridge-context.ps1 \
  scripts/run-supervisor.py \
  ai_orchestrator/adapters.py

run_case FAST_GATE \
  scripts/feature-handoff.ps1 \
  scripts/feature-handoff-lib.ps1 \
  scripts/install-feature-handoff.ps1 \
  scripts/feature-handoff-status.ps1 \
  tests/feature-handoff.tests.ps1 \
  production/accepted-preview/arthur-adh-quickstart.json

run_case FAST_GATE \
  .gitignore \
  AGENTS.md \
  scripts/live-preview.ps1 \
  scripts/live-preview-mature-safe.ps1 \
  scripts/prepare-live-preview-sources.ps1 \
  production/live-preview-policy.json \
  production/mature-ui-sources.json \
  tests/test-live-preview-contract.sh

run_case IMAGEBUILDER \
  production/v4/imagebuilder-request.json \
  v4/imagebuilder/packages.txt \
  v4/imagebuilder/files/etc/config/xinzhao \
  scripts/v4-imagebuilder-build.sh

run_case IMAGEBUILDER \
  files/etc/uci-defaults/99-xinzhao-defaults \
  files/etc/init.d/uhttpd \
  files/etc/config/xinzhao

run_case IMAGEBUILDER \
  files/usr/lib/lua/luci/controller/AdGuardHome.lua \
  files/usr/share/rpcd/acl.d/luci-app-adguardhome.json \
  files/www/luci-static/quickstart/index.js

run_case SDK_BUILD \
  production/v4/sdk-request.json \
  v4/sdk/packages/luci-app-example/Makefile \
  scripts/v4-sdk-build.sh

run_case SDK_BUILD \
  sources/kenzok8/quickstart/Makefile

run_case FULL_BUILD \
  config/arthur.config

run_case FULL_BUILD \
  config/required-plugins.txt \
  target/linux/qualcommax/image/example.mk

run_case FULL_BUILD \
  patches/901-arthur-upload-oom.patch \
  scripts/build.sh

run_case FULL_BUILD \
  production/v4/full-request.json \
  v4/full/kernel-change.marker

run_case FULL_BUILD \
  some/new-unknown-path.txt

run_case IMAGEBUILDER \
  README.md \
  .github/workflows/arthur-update-v3.yml \
  v4/imagebuilder/packages.txt

run_case IMAGEBUILDER \
  README.md \
  files/etc/uci-defaults/99-xinzhao-defaults

run_case SDK_BUILD \
  README.md \
  v4/imagebuilder/packages.txt \
  v4/sdk/packages/luci-app-example/Makefile

run_case SDK_BUILD \
  README.md \
  files/etc/uci-defaults/99-xinzhao-defaults \
  sources/kenzok8/quickstart/Makefile

run_case FULL_BUILD \
  README.md \
  v4/imagebuilder/packages.txt \
  v4/sdk/packages/luci-app-example/Makefile \
  config/arthur.config

run_contract_case DOC_ONLY NONE false HANDOFF.md knowledge/PROJECT-STATE.md
run_contract_case CONTROL_PLANE_ONLY CONTROL_EVIDENCE_ONLY false scripts/feature-handoff-status.ps1 scripts/ci-controller-v3.ps1
run_contract_case PREVIEW_BYTES PREVIEW_AND_DOWNSTREAM true production/accepted-preview/arthur-adh-quickstart.json
run_contract_case FIRMWARE_INPUT BUILD_AND_DOWNSTREAM true files/etc/config/xinzhao config/arthur.config
run_contract_case DEVICE_WRITE_POLICY PREFLASH_AND_DOWNSTREAM false production/known-good.json

echo 'PASS: build scope classifier behavior is correct.'
echo 'PASS: release impact classifier behavior is correct.'
