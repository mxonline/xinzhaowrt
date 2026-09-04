#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
REPOSITORY="${1:-${GITHUB_REPOSITORY:-mxonline/xinzhaowrt}}"
WORKFLOW="${2:-arthur-update-v3.yml}"
SOURCE_REF="${3:-HEAD}"
FINGERPRINT_SCRIPT="$ROOT/scripts/build-fingerprint.sh"
IMPACT_SCRIPT="$ROOT/scripts/source-impact-gate.sh"

ensure_commit() {
  local sha="$1"
  if git -C "$ROOT" rev-parse --verify "${sha}^{commit}" >/dev/null 2>&1; then
    return 0
  fi
  git -C "$ROOT" fetch --quiet origin "$sha" || return 1
  git -C "$ROOT" rev-parse --verify "${sha}^{commit}" >/dev/null 2>&1
}

current_sha="$(git -C "$ROOT" rev-parse "${SOURCE_REF}^{commit}")"
current_fp="$(bash "$FINGERPRINT_SCRIPT" "$current_sha")"
[[ "$current_fp" =~ ^arthur-build-v1:[0-9a-f]{64}$ ]] || {
  echo "ERROR: invalid current build fingerprint: $current_fp" >&2
  exit 2
}

runs_json="$(gh run list --repo "$REPOSITORY" --workflow "$WORKFLOW" --event workflow_dispatch --limit 100 --json databaseId,headSha,headBranch,status,conclusion,createdAt)"
mapfile -t runs < <(RUNS_JSON="$runs_json" python3 - <<'PY'
import json, os
runs=json.loads(os.environ.get('RUNS_JSON') or '[]')
runs.sort(key=lambda r: (str(r.get('createdAt') or ''), int(r.get('databaseId') or 0)), reverse=True)
for r in runs:
    print('\t'.join([
        str(r.get('databaseId') or ''),
        str(r.get('headSha') or ''),
        str(r.get('status') or ''),
        str(r.get('conclusion') or ''),
        str(r.get('headBranch') or ''),
    ]))
PY
)

latest_run_id=''
latest_sha=''
latest_status=''
latest_conclusion=''

for line in "${runs[@]:-}"; do
  [[ -z "$line" ]] && continue
  IFS=$'\t' read -r run_id sha status conclusion head_branch <<< "$line"
  [[ -z "$latest_run_id" ]] && {
    latest_run_id="$run_id"
    latest_sha="$sha"
    latest_status="$status"
    latest_conclusion="$conclusion"
  }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  ensure_commit "$sha" || continue
  run_fp="$(bash "$FINGERPRINT_SCRIPT" "$sha")"
  [[ "$run_fp" == "$current_fp" ]] || continue

  case "$status" in
    queued|in_progress|waiting|requested|pending)
      printf 'ACTION=WATCH_EXISTING_RUN\nRUN_ID=%s\nBUILD_FINGERPRINT=%s\nSOURCE_SHA=%s\n' "$run_id" "$current_fp" "$current_sha"
      exit 0
      ;;
    completed)
      if [[ "$conclusion" == success ]]; then
        printf 'ACTION=REUSE_ARTIFACT\nRUN_ID=%s\nBUILD_FINGERPRINT=%s\nSOURCE_SHA=%s\n' "$run_id" "$current_fp" "$current_sha"
        exit 0
      fi
      ;;
  esac
done

if [[ -n "$latest_sha" && "$latest_sha" =~ ^[0-9a-f]{40}$ ]] && ensure_commit "$latest_sha"; then
  impact="$(bash "$IMPACT_SCRIPT" "$latest_sha" "$current_sha")"
  if [[ "$impact" == NO_FIRMWARE_CHANGE$'\t'* ]]; then
    printf 'ACTION=NO_NEW_CANDIDATE\nRUN_ID=%s\nBUILD_FINGERPRINT=%s\nSOURCE_SHA=%s\nSOURCE_IMPACT=%s\n' \
      "$latest_run_id" "$current_fp" "$current_sha" "${impact//$'\t'/:}"
    exit 0
  fi
  printf 'ACTION=NEW_CANDIDATE\nRUN_ID=\nBUILD_FINGERPRINT=%s\nSOURCE_SHA=%s\nSOURCE_IMPACT=%s\n' \
    "$current_fp" "$current_sha" "${impact//$'\t'/:}"
  exit 0
fi

# Bootstrap/migration case: no inspectable prior Candidate. A new Candidate is allowed
# only because there is no prior build source against which source impact can be proven.
printf 'ACTION=NEW_CANDIDATE\nRUN_ID=\nBUILD_FINGERPRINT=%s\nSOURCE_SHA=%s\nSOURCE_IMPACT=BOOTSTRAP_NO_PRIOR_CANDIDATE\n' \
  "$current_fp" "$current_sha"
