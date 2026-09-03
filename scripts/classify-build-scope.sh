#!/usr/bin/env bash
set -euo pipefail

# Default mode preserves the legacy interface and prints exactly one build scope:
#   DOC_ONLY / FAST_GATE / IMAGEBUILDER / SDK_BUILD / FULL_BUILD
#
# --release-contract emits the orthogonal machine contract used to invalidate
# only the minimum evidence required by a change. It does not add a release Gate.

contract_mode=false
if [[ "${1:-}" == '--release-contract' ]]; then
  contract_mode=true
  shift
fi
if (( $# > 0 )); then
  printf 'ERROR: unsupported argument: %s\n' "$1" >&2
  exit 2
fi

scope='DOC_ONLY'
scope_rank=0
impact_class='DOC_ONLY'
impact_rank=0

promote_scope() {
  local candidate="$1"
  local rank
  case "$candidate" in
    DOC_ONLY)     rank=0 ;;
    FAST_GATE)    rank=1 ;;
    IMAGEBUILDER) rank=2 ;;
    SDK_BUILD)    rank=3 ;;
    FULL_BUILD)   rank=4 ;;
    *) printf 'ERROR: unknown scope %s\n' "$candidate" >&2; exit 2 ;;
  esac
  if (( rank > scope_rank )); then
    scope="$candidate"
    scope_rank="$rank"
  fi
}

promote_impact() {
  local candidate="$1"
  local rank
  # Rank is invalidation breadth, not build cost. Preview bytes are earliest in
  # the reusable evidence chain; firmware inputs subsume pre-flash safety.
  case "$candidate" in
    DOC_ONLY)            rank=0 ;;
    CONTROL_PLANE_ONLY)  rank=1 ;;
    DEVICE_WRITE_POLICY) rank=2 ;;
    FIRMWARE_INPUT)      rank=3 ;;
    PREVIEW_BYTES)       rank=4 ;;
    *) printf 'ERROR: unknown release impact class %s\n' "$candidate" >&2; exit 2 ;;
  esac
  if (( rank > impact_rank )); then
    impact_class="$candidate"
    impact_rank="$rank"
  fi
}

classify_release_impact() {
  local path="$1"
  case "$path" in
    HANDOFF.md|README.md|README.*|docs/*|knowledge/*)
      promote_impact DOC_ONLY
      ;;

    production/accepted-preview/*|production/live-preview-policy.json|production/mature-ui-sources.json)
      promote_impact PREVIEW_BYTES
      ;;

    production/known-good.json|production/arthur-known-good-v1.json|production/arthur-flash-profile.json|\
    production/real-device-baseline.json|production/expected-diff.json|production/fast-safe-release-policy.json)
      promote_impact DEVICE_WRITE_POLICY
      ;;

    .gitignore|AGENTS.md|.github/*|tests/*|requirements-headless.txt|ai_orchestrator/*|\
    scripts/classify-build-scope.sh|scripts/analyze-error.sh|scripts/verify-project.sh|\
    scripts/check-defaults.sh|scripts/check-upload-oom-fix.sh|scripts/real-device-verify*.ps1|\
    scripts/production-agent.ps1|scripts/install-production-agent.ps1|scripts/uninstall-production-agent.ps1|\
    scripts/start-production-agent.ps1|scripts/production-agent-status.ps1|scripts/ci-controller-v3.ps1|\
    scripts/feature-handoff.ps1|scripts/feature-handoff-lib.ps1|scripts/install-feature-handoff.ps1|\
    scripts/feature-handoff-status.ps1|scripts/fast-safe-release-lib.ps1|\
    scripts/bridge-runtime-status.ps1|scripts/recover-existing-bridge-context.ps1|scripts/run-supervisor.py|\
    scripts/repair-github-runner.ps1|scripts/bootstrap-arthur-host-key.ps1|\
    scripts/fetch-production-artifact.ps1|scripts/auto-flash-safety-gate.ps1|\
    scripts/real-device-baseline-lib.ps1|scripts/real-device-snapshot.ps1|scripts/real-device-baseline-gate.ps1|\
    scripts/v4-controller*.sh|scripts/baseline-integrity-gate.sh|scripts/v4-pipeline-dry-run.sh|\
    production/v3-request.json|production/request.json|production/known-good-request.json|\
    production/v4-state.json|production/production-agent.json)
      promote_impact CONTROL_PLANE_ONLY
      ;;

    files/*|config/*|patches/*|package/*|packages/*|feeds/*|sources/*|target/*|\
    VERSION|build.env|scripts/build.sh|scripts/codex-setup.sh|scripts/add-custom-packages.sh|\
    scripts/prepare-update-lock.sh|scripts/check-package-existence.sh|scripts/apply-*|scripts/fetch-*|\
    production/v4/imagebuilder-request.json|production/v4/sdk-request.json|production/v4/full-request.json|\
    v4/imagebuilder/*|v4/sdk/*|v4/full/*|scripts/v4-imagebuilder*.sh|scripts/v4-sdk*.sh)
      promote_impact FIRMWARE_INPUT
      ;;

    *)
      # Unknown inputs fail closed as firmware-affecting. This can cost a build,
      # but never silently reuses stale bytes when provenance is unknown.
      promote_impact FIRMWARE_INPUT
      ;;
  esac
}

while IFS= read -r path; do
  [[ -z "$path" ]] && continue

  classify_release_impact "$path"

  case "$path" in
    HANDOFF.md|README.md|README.*|docs/*|knowledge/*)
      ;;

    .gitignore|AGENTS.md|.github/*|tests/*|requirements-headless.txt|ai_orchestrator/*|\
    scripts/classify-build-scope.sh|scripts/analyze-error.sh|scripts/verify-project.sh|\
    scripts/check-defaults.sh|scripts/check-upload-oom-fix.sh|scripts/real-device-verify*.ps1|\
    scripts/production-agent.ps1|scripts/install-production-agent.ps1|scripts/uninstall-production-agent.ps1|\
    scripts/start-production-agent.ps1|scripts/production-agent-status.ps1|scripts/ci-controller-v3.ps1|\
    scripts/feature-handoff.ps1|scripts/feature-handoff-lib.ps1|scripts/install-feature-handoff.ps1|scripts/feature-handoff-status.ps1|\
    scripts/fast-safe-release-lib.ps1|\
    scripts/bridge-runtime-status.ps1|scripts/recover-existing-bridge-context.ps1|scripts/run-supervisor.py|\
    scripts/repair-github-runner.ps1|scripts/bootstrap-arthur-host-key.ps1|\
    scripts/fetch-production-artifact.ps1|scripts/auto-flash-safety-gate.ps1|\
    scripts/real-device-baseline-lib.ps1|scripts/real-device-snapshot.ps1|scripts/real-device-baseline-gate.ps1|\
    scripts/live-preview.ps1|scripts/live-preview-mature-safe.ps1|scripts/prepare-live-preview-sources.ps1|\
    scripts/v4-controller*.sh|scripts/baseline-integrity-gate.sh|scripts/v4-pipeline-dry-run.sh|\
    production/v3-request.json|production/request.json|production/known-good-request.json|\
    production/v4-state.json|production/known-good.json|production/arthur-known-good-v1.json|\
    production/production-agent.json|production/arthur-flash-profile.json|\
    production/real-device-baseline.json|production/expected-diff.json|\
    production/live-preview-policy.json|production/mature-ui-sources.json|production/accepted-preview/*|\
    production/fast-safe-release-policy.json)
      promote_scope FAST_GATE
      ;;

    production/v4/imagebuilder-request.json|v4/imagebuilder/*|scripts/v4-imagebuilder*.sh)
      promote_scope IMAGEBUILDER
      ;;

    files/etc/uci-defaults/*|files/etc/init.d/*|files/etc/config/*|\
    files/usr/lib/lua/luci/*|files/usr/share/rpcd/acl.d/*|files/usr/share/AdGuardHome/*|\
    files/www/luci-static/*)
      promote_scope IMAGEBUILDER
      ;;

    production/v4/sdk-request.json|v4/sdk/*|scripts/v4-sdk*.sh)
      promote_scope SDK_BUILD
      ;;

    sources/kenzok8/quickstart/*|package/feeds/*/quickstart/*)
      promote_scope SDK_BUILD
      ;;

    production/v4/full-request.json|v4/full/*|config/*|files/*|patches/*|package/*|packages/*|feeds/*|VERSION|build.env|scripts/build.sh|scripts/codex-setup.sh|scripts/add-custom-packages.sh|scripts/prepare-update-lock.sh|scripts/check-package-existence.sh|scripts/apply-*|scripts/fetch-*)
      promote_scope FULL_BUILD
      ;;

    *)
      promote_scope FULL_BUILD
      ;;
  esac
done

if [[ "$contract_mode" == false ]]; then
  printf '%s\n' "$scope"
  exit 0
fi

case "$impact_class" in
  DOC_ONLY)
    minimum_invalidation='NONE'
    firmware_build_required='false'
    ;;
  CONTROL_PLANE_ONLY)
    minimum_invalidation='CONTROL_EVIDENCE_ONLY'
    firmware_build_required='false'
    ;;
  PREVIEW_BYTES)
    minimum_invalidation='PREVIEW_AND_DOWNSTREAM'
    firmware_build_required='true'
    ;;
  FIRMWARE_INPUT)
    minimum_invalidation='BUILD_AND_DOWNSTREAM'
    firmware_build_required='true'
    ;;
  DEVICE_WRITE_POLICY)
    minimum_invalidation='PREFLASH_AND_DOWNSTREAM'
    firmware_build_required='false'
    ;;
  *)
    printf 'ERROR: unresolved release impact class %s\n' "$impact_class" >&2
    exit 2
    ;;
esac

printf 'LEGACY_BUILD_SCOPE=%s\n' "$scope"
printf 'RELEASE_IMPACT_CLASS=%s\n' "$impact_class"
printf 'MINIMUM_INVALIDATION=%s\n' "$minimum_invalidation"
printf 'FIRMWARE_BUILD_REQUIRED=%s\n' "$firmware_build_required"
