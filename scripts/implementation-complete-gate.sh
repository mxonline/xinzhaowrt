#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="${1:-production/current-changeset.json}"
EXPECTED_CHANGESET_ID="${2:-${CHANGESET_ID:-}}"
EXPECTED_SOURCE_SHA="${3:-${SOURCE_SHA:-}}"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "STATE_FILE_MISSING=$STATE_FILE" >&2
  exit 20
fi

python3 - "$STATE_FILE" "$EXPECTED_CHANGESET_ID" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
expected_changeset = sys.argv[2]

try:
    data = json.loads(state_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"STATE_JSON_INVALID={exc}", file=sys.stderr)
    raise SystemExit(21)

required = data.get("required_tasks")
tasks = data.get("tasks")
if not isinstance(required, list) or not required:
    print("REQUIRED_TASKS_INVALID", file=sys.stderr)
    raise SystemExit(22)
if not isinstance(tasks, dict) or not tasks:
    print("TASK_MAP_INVALID", file=sys.stderr)
    raise SystemExit(23)

missing = [name for name in required if name not in tasks]
if missing:
    print("TASK_MISSING=" + ",".join(missing), file=sys.stderr)
    raise SystemExit(24)

not_pass = [f"{name}:{tasks.get(name)}" for name in required if tasks.get(name) != "PASS"]
if not_pass:
    print("TASK_NOT_PASS=" + ",".join(not_pass), file=sys.stderr)
    raise SystemExit(25)

if data.get("implementation_complete") is not True:
    print("IMPLEMENTATION_COMPLETE_FALSE", file=sys.stderr)
    raise SystemExit(26)

if data.get("frozen") is not True:
    print("CHANGESET_NOT_FROZEN", file=sys.stderr)
    raise SystemExit(27)

changeset_id = data.get("changeset_id")
if not isinstance(changeset_id, str) or not changeset_id.strip():
    print("CHANGESET_ID_INVALID", file=sys.stderr)
    raise SystemExit(28)

if expected_changeset and expected_changeset != changeset_id:
    print(f"CHANGESET_ID_MISMATCH expected={expected_changeset} actual={changeset_id}", file=sys.stderr)
    raise SystemExit(29)

if data.get("build_class") not in ("FROZEN_PRODUCTION", "PRODUCTION"):
    print(f"BUILD_CLASS_NOT_PRODUCTION={data.get('build_class')}", file=sys.stderr)
    raise SystemExit(30)

print(f"CHANGESET_ID={changeset_id}")
print("ALL_REQUIRED_TASKS=PASS")
PY

if [[ -n "$EXPECTED_SOURCE_SHA" ]]; then
  ACTUAL_SOURCE_SHA="${CURRENT_SOURCE_SHA:-${GITHUB_SHA:-}}"
  if [[ -z "$ACTUAL_SOURCE_SHA" ]] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ACTUAL_SOURCE_SHA="$(git rev-parse HEAD)"
  fi
  if [[ -z "$ACTUAL_SOURCE_SHA" ]]; then
    echo "SOURCE_SHA_UNAVAILABLE" >&2
    exit 31
  fi
  if [[ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA" ]]; then
    echo "SOURCE_SHA_MISMATCH expected=$EXPECTED_SOURCE_SHA actual=$ACTUAL_SOURCE_SHA" >&2
    exit 32
  fi
  echo "SOURCE_SHA_MATCH=$ACTUAL_SOURCE_SHA"
fi

echo "IMPLEMENTATION_COMPLETE_GATE=PASS"
