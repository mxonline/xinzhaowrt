#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/scripts/v4-toolchain-bootstrap.sh"
WORKFLOW="$ROOT/.github/workflows/arthur-toolchain-bootstrap-v4.yml"
LEGACY_RUN_ID='33182381566'

[[ -x "$BOOTSTRAP" ]] || {
  echo "FAIL: missing executable scripts/v4-toolchain-bootstrap.sh" >&2
  exit 1
}

readarray -t EXPECTED < <(python3 - "$ROOT/production/known-good.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
print(d['stable_tag'])
print(d['upstream_commit'])
print(f"{d['target']}/{d['subtarget']}")
print(d['device'])
PY
)

plan="$("$BOOTSTRAP" --plan)"

grep -qx 'MODE=PLAN' <<<"$plan"
grep -qx "KNOWN_GOOD_TAG=${EXPECTED[0]}" <<<"$plan"
grep -qx "UPSTREAM_COMMIT=${EXPECTED[1]}" <<<"$plan"
grep -qx "TARGET=${EXPECTED[2]}" <<<"$plan"
grep -qx "PROFILE=${EXPECTED[3]}" <<<"$plan"
grep -qx 'CONFIG_SDK=y' <<<"$plan"
grep -qx 'CONFIG_IB=y' <<<"$plan"
grep -qx 'CONFIG_IB_STANDALONE=y' <<<"$plan"

# The current production schema uses verified=true + status=frozen for an
# immutable real-device-confirmed Known-Good. That state must remain accepted.
tmp_frozen="$(mktemp)"
tmp_bad="$(mktemp)"
trap 'rm -f "$tmp_frozen" "$tmp_bad"' EXIT
python3 - "$ROOT/production/known-good.json" "$tmp_frozen" <<'PY'
import json, sys
src, dst = sys.argv[1:]
obj = json.load(open(src, encoding='utf-8'))
obj['verified'] = True
obj['status'] = 'frozen'
obj['verification'] = 'real-device-confirmed'
json.dump(obj, open(dst, 'w', encoding='utf-8'), indent=2)
PY
KNOWN_GOOD_JSON="$tmp_frozen" "$BOOTSTRAP" --plan >/dev/null

# Bootstrap must still fail closed for unverified/candidate records.
python3 - "$ROOT/production/known-good.json" "$tmp_bad" <<'PY'
import json, sys
src, dst = sys.argv[1:]
obj = json.load(open(src, encoding='utf-8'))
obj['verified'] = False
obj['status'] = 'candidate'
json.dump(obj, open(dst, 'w', encoding='utf-8'), indent=2)
PY

if KNOWN_GOOD_JSON="$tmp_bad" "$BOOTSTRAP" --plan >/dev/null 2>&1; then
  echo 'FAIL: bootstrap accepted an unverified Known-Good record' >&2
  exit 1
fi

[[ -f "$WORKFLOW" ]] || {
  echo 'FAIL: missing arthur-toolchain-bootstrap-v4.yml' >&2
  exit 1
}

grep -q 'workflow_dispatch:' "$WORKFLOW"
grep -q 'workflow_run:' "$WORKFLOW"
grep -q 'Arthur Known-Good Fast Lane v1' "$WORKFLOW"
grep -q "github.event.workflow_run.id == ${LEGACY_RUN_ID}" "$WORKFLOW"
grep -q 'v4-toolchain-bootstrap.sh --plan' "$WORKFLOW"
grep -q 'v4-toolchain-bootstrap.sh --execute' "$WORKFLOW"
grep -q 'actions/upload-artifact@v4' "$WORKFLOW"

# The bootstrap may auto-handoff only from the one legacy run, never from arbitrary pushes.
if grep -Eq '^[[:space:]]+push:' "$WORKFLOW"; then
  echo 'FAIL: v4 toolchain bootstrap must not auto-run on push' >&2
  exit 1
fi

# v4 controller has landed on main; workflow_run must consume the default-branch implementation.
grep -q '^[[:space:]]*ref: main$' "$WORKFLOW" || {
  echo 'FAIL: v4 toolchain bootstrap must checkout main after controller merge' >&2
  exit 1
}

echo 'PASS: v4 toolchain bootstrap accepts verified frozen baseline and rejects unverified candidates.'
