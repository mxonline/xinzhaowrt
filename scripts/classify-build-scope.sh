#!/usr/bin/env bash
set -euo pipefail

# Reads repository-relative changed paths from stdin and prints exactly one scope:
#   DOC_ONLY     - documentation/knowledge only; no firmware build required.
#   FAST_GATE    - CI, verifier, test, or control-plane-only change; run static gates.
#   IMAGEBUILDER - explicit v4 image assembly change using ABI-compatible prebuilt packages.
#   SDK_BUILD    - explicit v4 user-space package rebuild using the Known-Good-matched SDK.
#   FULL_BUILD   - firmware/kernel/unknown change; require a full Candidate build.
#
# Safety rule: unknown paths are FULL_BUILD. The highest-risk scope always wins.

scope='DOC_ONLY'
scope_rank=0

promote_scope() {
  local candidate="$1"
  local rank

  case "$candidate" in
    DOC_ONLY)     rank=0 ;;
    FAST_GATE)    rank=1 ;;
    IMAGEBUILDER) rank=2 ;;
    SDK_BUILD)    rank=3 ;;
    FULL_BUILD)   rank=4 ;;
    *)
      printf 'ERROR: unknown scope %s\n' "$candidate" >&2
      exit 2
      ;;
  esac

  if (( rank > scope_rank )); then
    scope="$candidate"
    scope_rank="$rank"
  fi
}

while IFS= read -r path; do
  [[ -z "$path" ]] && continue

  case "$path" in
    README.md|README.*|docs/*|knowledge/*)
      ;;

    AGENTS.md|.github/*|tests/*|requirements-headless.txt|ai_orchestrator/*|\
    scripts/classify-build-scope.sh|scripts/analyze-error.sh|scripts/verify-project.sh|\
    scripts/check-defaults.sh|scripts/check-upload-oom-fix.sh|scripts/real-device-verify*.ps1|\
    scripts/production-agent.ps1|scripts/install-production-agent.ps1|scripts/uninstall-production-agent.ps1|\
    scripts/start-production-agent.ps1|scripts/production-agent-status.ps1|scripts/ci-controller-v3.ps1|\
    scripts/bridge-runtime-status.ps1|scripts/recover-existing-bridge-context.ps1|scripts/run-supervisor.py|\
    scripts/repair-github-runner.ps1|scripts/bootstrap-arthur-host-key.ps1|\
    scripts/fetch-production-artifact.ps1|scripts/auto-flash-safety-gate.ps1|\
    scripts/real-device-baseline-lib.ps1|scripts/real-device-snapshot.ps1|scripts/real-device-baseline-gate.ps1|\
    scripts/live-preview.ps1|\
    scripts/v4-controller*.sh|scripts/baseline-integrity-gate.sh|scripts/v4-pipeline-dry-run.sh|\
    production/v3-request.json|production/request.json|production/known-good-request.json|\
    production/v4-state.json|production/known-good.json|production/arthur-known-good-v1.json|\
    production/production-agent.json|production/arthur-flash-profile.json|\
    production/real-device-baseline.json|production/expected-diff.json|\
    production/live-preview-policy.json)
      promote_scope FAST_GATE
      ;;

    production/v4/imagebuilder-request.json|v4/imagebuilder/*|scripts/v4-imagebuilder*.sh)
      promote_scope IMAGEBUILDER
      ;;

    files/etc/uci-defaults/*|files/etc/init.d/*|files/etc/config/*)
      promote_scope IMAGEBUILDER
      ;;

    production/v4/sdk-request.json|v4/sdk/*|scripts/v4-sdk*.sh)
      promote_scope SDK_BUILD
      ;;

    sources/kenzok8/quickstart/*|package/feeds/*/quickstart/*)
      promote_scope SDK_BUILD
      ;;

    production/v4/full-request.json|v4/full/*|config/*|files/*|patches/*|package/*|packages/*|feeds/*|VERSION|build.env|scripts/build.sh|scripts/codex-setup.sh|scripts/add-custom-packages.sh|scripts/prepare-update-lock.sh|scripts/check-package-existence.sh|scripts/apply-*|scripts/fetch-*|production/known-good.json)
      promote_scope FULL_BUILD
      break
      ;;

    *)
      # Fail closed: an unclassified path must never bypass a real build.
      promote_scope FULL_BUILD
      break
      ;;
  esac
done

printf '%s\n' "$scope"
