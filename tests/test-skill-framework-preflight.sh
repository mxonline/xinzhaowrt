#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/skill-framework-preflight.sh"
STATE="$ROOT/production/skill-framework-state.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -x "$SCRIPT" ]] || fail "preflight script is missing or not executable"
[[ -f "$ROOT/production/known-good.json" ]] || fail "known-good metadata missing"
python3 -m json.tool "$ROOT/production/v4-state.json" >/dev/null

"$SCRIPT" >/tmp/xinzhao-skill-framework-preflight.out

[[ -f "$STATE" ]] || fail "framework state file was not written"
python3 - "$STATE" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))

assert state["schema_version"] == "0.1"
assert state["framework_mode"] == "DRY_RUN_ONLY"
assert state["baseline_integrity"] == "PASS"
assert state["flash_policy_sync"] == "BLOCKED"
assert state["verified_flash_method"] == "BLOCKED"
assert state["production_takeover"] is False
assert state["build_requested"] is False
assert state["flash_requested"] is False

conflicts = state.get("conflicts") or []
assert any("HUMAN_REVIEW_GATE" in item for item in conflicts), conflicts
assert any("manual" in item.lower() or "human" in item.lower() for item in conflicts), conflicts
PY

printf 'SKILL_FRAMEWORK_PREFLIGHT_TEST=PASS\n'
