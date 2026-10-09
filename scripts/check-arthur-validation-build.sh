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
git -C "$PROJECT_ROOT" merge-base --is-ancestor "$ARTHUR_CANDIDATE_SHA" "$actual_sha" || {
  echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
  echo "ERROR: frozen firmware source $ARTHUR_CANDIDATE_SHA is not an ancestor of checked-out project $actual_sha." >&2
  exit 1
}

allowed_control_path() {
  case "$1" in
    AGENTS.md|\
    HANDOFF.md|\
    .github/workflows/*|\
    production/evidence/*|\
    production/operator-intent.json|\
    production/resume-state.json|\
    production/firmware-events.jsonl|\
    scripts/arthur-device-identity-forensics.ps1|\
    scripts/arthur-evidence-index.ps1|\
    scripts/arthur-resume-state.ps1|\
    scripts/arthur-state-contract.ps1|\
    scripts/bind-prebuild-openclash-adh-evidence.py|\
    scripts/build.sh|\
    scripts/derive-stable-overlay-manifest.py|\
    scripts/luci-legacy-template-smoke.py|\
    scripts/check-arthur-validation-build.sh|\
    scripts/check-openclash-adh-prebuild-live.py|\
    scripts/collect-arthur-openclash-adh-readonly.ps1|\
    scripts/ensure-arthur-unattended-access.ps1|\
    scripts/verify-project.ps1|\
    scripts/verify-project.sh|\
    scripts/arthur-*.ps1|\
    scripts/arthur-*.py|\
    tests/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  if ! allowed_control_path "$changed_path"; then
    echo 'VALIDATION_BUILD_ALLOWED=FAIL' >&2
    echo "ERROR: post-freeze change is outside the control/evidence allowlist: $changed_path" >&2
    exit 1
  fi
  echo "POST_FREEZE_CONTROL_CHANGE=PASS path=$changed_path"
done < <(git -C "$PROJECT_ROOT" diff --name-only "$ARTHUR_CANDIDATE_SHA" "$actual_sha")

echo "ARTHUR_CANDIDATE_SHA=$ARTHUR_CANDIDATE_SHA"
echo "ARTHUR_VALIDATION_COMMIT=$actual_sha"
echo 'VALIDATION_BUILD_ALLOWED=PASS'
