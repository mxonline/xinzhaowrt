#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_DIR="${1:-$PROJECT_ROOT/output/logs}"
OUT_DIR="$PROJECT_ROOT/output/logs"
CURRENT_FP="$OUT_DIR/failure-fingerprint.json"
REPORT="$OUT_DIR/repair-regression.json"
mkdir -p "$OUT_DIR"

python3 "$PROJECT_ROOT/scripts/failure-fingerprint.py" "$CURRENT_DIR" --output "$CURRENT_FP" >/dev/null

commit_message="${GITHUB_HEAD_COMMIT_MESSAGE:-}"
if [[ -z "$commit_message" ]]; then
  commit_message="$(git -C "$PROJECT_ROOT" log -1 --pretty=%B 2>/dev/null || true)"
fi

if [[ ! "$commit_message" =~ auto-repair[[:space:]]+run[[:space:]]+([0-9]+)[[:space:]]+round[[:space:]]+([0-9]+) ]]; then
  python3 - "$CURRENT_FP" "$REPORT" <<'PY'
import json
import sys
from datetime import datetime, timezone

current = json.load(open(sys.argv[1], encoding='utf-8'))
report = {
    'schema_version': '1.0',
    'status': 'BASELINE_FAILURE',
    'message': 'Current failure is not linked to an automatic repair commit; no previous error signature is available for regression comparison.',
    'current_root_signature': current.get('root_signature'),
    'current_stage': current.get('stage'),
    'current_kind': current.get('kind'),
    'current_signals': current.get('signals', []),
    'generated_at': datetime.now(timezone.utc).isoformat(),
}
open(sys.argv[2], 'w', encoding='utf-8').write(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
PY
  echo 'REGRESSION_GATE: BASELINE_FAILURE'
  exit 0
fi

PREVIOUS_RUN_ID="${BASH_REMATCH[1]}"
REPAIR_ROUND="${BASH_REMATCH[2]}"
PREVIOUS_ROOT="$PROJECT_ROOT/output/regression/previous-$PREVIOUS_RUN_ID"
PREVIOUS_FP="$PROJECT_ROOT/output/regression/previous-$PREVIOUS_RUN_ID-fingerprint.json"
rm -rf "$PREVIOUS_ROOT"
mkdir -p "$PREVIOUS_ROOT" "$(dirname "$PREVIOUS_FP")"

if [[ -n "${PREVIOUS_DIAGNOSTICS_DIR:-}" ]]; then
  cp -a "$PREVIOUS_DIAGNOSTICS_DIR"/. "$PREVIOUS_ROOT"/
else
  if ! gh run download "$PREVIOUS_RUN_ID" \
      --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
      --name "XinZhaoWrt-diagnostics-$PREVIOUS_RUN_ID" \
      --dir "$PREVIOUS_ROOT"; then
    python3 - "$CURRENT_FP" "$REPORT" "$PREVIOUS_RUN_ID" "$REPAIR_ROUND" <<'PY'
import json
import sys
from datetime import datetime, timezone

current = json.load(open(sys.argv[1], encoding='utf-8'))
report = {
    'schema_version': '1.0',
    'status': 'BLOCKED_PREVIOUS_DIAGNOSTICS_UNAVAILABLE',
    'message': 'Automatic repair cannot be regression-verified because the previous failed run diagnostics could not be downloaded.',
    'previous_run_id': int(sys.argv[3]),
    'repair_round': int(sys.argv[4]),
    'current_root_signature': current.get('root_signature'),
    'current_stage': current.get('stage'),
    'current_kind': current.get('kind'),
    'current_signals': current.get('signals', []),
    'generated_at': datetime.now(timezone.utc).isoformat(),
}
open(sys.argv[2], 'w', encoding='utf-8').write(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
PY
    echo "REGRESSION_GATE: BLOCKED_PREVIOUS_DIAGNOSTICS_UNAVAILABLE previous_run=$PREVIOUS_RUN_ID" >&2
    exit 44
  fi
fi

python3 "$PROJECT_ROOT/scripts/failure-fingerprint.py" "$PREVIOUS_ROOT" --output "$PREVIOUS_FP" >/dev/null

set +e
python3 - "$PREVIOUS_FP" "$CURRENT_FP" "$REPORT" "$PREVIOUS_RUN_ID" "$REPAIR_ROUND" <<'PY'
import json
import sys
from datetime import datetime, timezone

previous = json.load(open(sys.argv[1], encoding='utf-8'))
current = json.load(open(sys.argv[2], encoding='utf-8'))
same = bool(previous.get('root_signature')) and previous.get('root_signature') == current.get('root_signature')
status = 'FAILED_SAME_ERROR' if same else 'OLD_ERROR_CLEARED_NEW_ERROR'
message = (
    'The previous repair did not remove the old root-cause signature. Do not accept or repeat the same repair; analyze why it was ineffective.'
    if same else
    'The previous root-cause signature is gone, but the build still fails with a different signature. The old repair is regression-verified; treat the current failure as a new root cause.'
)
report = {
    'schema_version': '1.0',
    'status': status,
    'message': message,
    'previous_run_id': int(sys.argv[4]),
    'repair_round': int(sys.argv[5]),
    'previous_root_signature': previous.get('root_signature'),
    'current_root_signature': current.get('root_signature'),
    'previous_stage': previous.get('stage'),
    'current_stage': current.get('stage'),
    'previous_kind': previous.get('kind'),
    'current_kind': current.get('kind'),
    'previous_signals': previous.get('signals', []),
    'current_signals': current.get('signals', []),
    'generated_at': datetime.now(timezone.utc).isoformat(),
}
open(sys.argv[3], 'w', encoding='utf-8').write(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(
    f"REGRESSION_GATE: {status} previous_run={sys.argv[4]} "
    f"previous={previous.get('root_signature')} current={current.get('root_signature')}"
)
sys.exit(42 if same else 0)
PY
rc=$?
set -e
exit "$rc"
