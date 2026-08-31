#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${CHANGESET_STATE_FILE:-$ROOT/production/current-changeset.json}"
EXPECTED_CHANGESET_ID="${EXPECTED_CHANGESET_ID:-}"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:-}"

fail() {
  echo "IMPLEMENTATION_COMPLETE_GATE=FAIL" >&2
  echo "CHANGESET_FREEZE=FAIL" >&2
  echo "CANDIDATE_ELIGIBLE=NO" >&2
  echo "GATE_REASON=$*" >&2
  exit 1
}

[[ -f "$STATE_FILE" ]] || fail "missing changeset state: $STATE_FILE"

if [[ -n "${GATE_HEAD:-}" ]]; then
  HEAD_SHA="$GATE_HEAD"
else
  command -v git >/dev/null 2>&1 || fail 'git is required to resolve source HEAD'
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || fail 'cannot resolve source HEAD'
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  fail 'python3/python is required to validate changeset state'
fi

set +e
GATE_OUTPUT="$($PYTHON_BIN - "$STATE_FILE" "$HEAD_SHA" "$EXPECTED_CHANGESET_ID" "$EXPECTED_SOURCE_SHA" <<'PY'
import json
import re
import sys
from pathlib import Path

state_path, head_sha, expected_id, expected_sha = sys.argv[1:5]
try:
    state = json.loads(Path(state_path).read_text(encoding="utf-8"))
except Exception as exc:
    print(f"invalid changeset json: {exc}")
    sys.exit(2)

required_keys = {
    "adguardhome_full_manager",
    "istoreos_original_quickstart",
    "wifi_real_connect_fix",
    "plugin_i18n",
    "argon_compatibility",
    "kucat_compatibility",
    "plugins_menu_cleanup",
    "baseline_regression",
}

if str(state.get("schema_version")) != "4.3":
    print("schema_version must be 4.3")
    sys.exit(3)

changeset_id = state.get("changeset_id")
if not isinstance(changeset_id, str) or not changeset_id.strip():
    print("changeset_id missing")
    sys.exit(4)
if expected_id and changeset_id != expected_id:
    print(f"changeset_id mismatch: state={changeset_id} expected={expected_id}")
    sys.exit(5)

tasks = state.get("required_tasks")
if not isinstance(tasks, dict):
    print("required_tasks missing")
    sys.exit(6)
missing = sorted(required_keys - set(tasks))
extra = sorted(set(tasks) - required_keys)
if missing:
    print("missing required tasks: " + ",".join(missing))
    sys.exit(7)
if extra:
    print("unexpected required tasks: " + ",".join(extra))
    sys.exit(8)
invalid = {k: v for k, v in tasks.items() if v not in {"PENDING", "PASS", "FAIL", "BLOCKED"}}
if invalid:
    print("invalid task states: " + repr(invalid))
    sys.exit(9)
not_pass = {k: v for k, v in tasks.items() if v != "PASS"}
if not_pass:
    print("required tasks not PASS: " + ", ".join(f"{k}={v}" for k, v in sorted(not_pass.items())))
    sys.exit(10)

if state.get("implementation_complete") is not True:
    print("implementation_complete must be true")
    sys.exit(11)
if state.get("frozen") is not True:
    print("frozen must be true")
    sys.exit(12)
if state.get("state") != "FROZEN":
    print("state must be FROZEN")
    sys.exit(13)

frozen_sha = state.get("frozen_source_sha")
if not isinstance(frozen_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", frozen_sha):
    print("frozen_source_sha must be a full 40-character lowercase git SHA")
    sys.exit(14)
if not re.fullmatch(r"[0-9a-f]{40}", head_sha):
    print("resolved HEAD is not a full git SHA")
    sys.exit(15)
if frozen_sha != head_sha:
    print(f"frozen source mismatch: frozen={frozen_sha} head={head_sha}")
    sys.exit(16)
if expected_sha and frozen_sha != expected_sha:
    print(f"expected source mismatch: frozen={frozen_sha} expected={expected_sha}")
    sys.exit(17)

# This gate authorizes only the production candidate build. Flash, real-device
# verification and release remain controlled by their own downstream gates.
policy = state.get("candidate_policy", {})
if policy.get("allow_candidate_build") is not True:
    print("candidate_policy.allow_candidate_build must be true after freeze")
    sys.exit(18)

if state.get("production_terminal_state") != "PRODUCTION_RELEASED":
    print("production_terminal_state must be PRODUCTION_RELEASED")
    sys.exit(19)

print(f"CHANGESET_ID={changeset_id}")
print(f"FROZEN_SOURCE_SHA={frozen_sha}")
PY
)"
GATE_RC=$?
set -e

if (( GATE_RC != 0 )); then
  [[ -n "$GATE_OUTPUT" ]] && echo "$GATE_OUTPUT" >&2
  fail "state validation failed (rc=$GATE_RC)"
fi

printf '%s\n' "$GATE_OUTPUT"
echo "IMPLEMENTATION_COMPLETE_GATE=PASS"
echo "CHANGESET_FREEZE=PASS"
echo "CANDIDATE_ELIGIBLE=YES"
