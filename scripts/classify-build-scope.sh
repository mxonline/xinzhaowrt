#!/usr/bin/env bash
set -euo pipefail

# Reads repository-relative changed paths from stdin and prints exactly one scope:
#   DOC_ONLY   - documentation/knowledge only; no firmware build required.
#   FAST_GATE  - CI, verifier, test, or control-plane-only change; run static gates.
#   FULL_BUILD - firmware-affecting or unknown change; require a full Candidate build.
#
# Safety rule: unknown paths are FULL_BUILD. The highest-risk scope always wins.

scope='DOC_ONLY'

promote_fast_gate() {
  if [[ "$scope" == 'DOC_ONLY' ]]; then
    scope='FAST_GATE'
  fi
}

while IFS= read -r path; do
  [[ -z "$path" ]] && continue

  case "$path" in
    README.md|README.*|docs/*|knowledge/*)
      ;;

    .github/*|tests/*|scripts/classify-build-scope.sh|scripts/analyze-error.sh|scripts/verify-project.sh|scripts/check-defaults.sh|scripts/check-upload-oom-fix.sh|scripts/real-device-verify*.ps1|production/v3-request.json|production/request.json|production/known-good-request.json)
      promote_fast_gate
      ;;

    config/*|files/*|patches/*|package/*|packages/*|feeds/*|VERSION|scripts/build.sh|scripts/codex-setup.sh|scripts/add-custom-packages.sh|scripts/prepare-update-lock.sh|scripts/check-package-existence.sh|scripts/apply-*|scripts/fetch-*|production/known-good.json)
      scope='FULL_BUILD'
      break
      ;;

    *)
      # Default closed: an unclassified path must never bypass a real build.
      scope='FULL_BUILD'
      break
      ;;
  esac
done

printf '%s\n' "$scope"
