#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/scripts/production-build-entry-gate.sh"
DEFAULTS="$ROOT/scripts/check-defaults.sh"
STATE="$ROOT/production/current-changeset.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "TEST_FAIL: $*" >&2; exit 1; }

[[ -f "$ENTRY" ]] || fail "production entry gate missing"
grep -q 'production-build-entry-gate.sh' "$DEFAULTS" || fail "check-defaults.sh does not invoke production entry gate"

for workflow in \
  'Arthur Theme Candidate SDK and ImageBuilder' \
  'Arthur Fast Candidate SDK and ImageBuilder' \
  'Build XinZhaoWrt Arthur'; do
  if GITHUB_WORKFLOW="$workflow" GITHUB_SHA=deadbeef bash "$ENTRY" >"$TMP/out" 2>"$TMP/err"; then
    fail "$workflow unexpectedly passed while current changeset is incomplete"
  fi
  grep -Eq 'TASK_NOT_PASS|IMPLEMENTATION_COMPLETE_FALSE|CHANGESET_NOT_FROZEN' "$TMP/err" || {
    cat "$TMP/out" "$TMP/err" >&2 || true
    fail "$workflow failed for the wrong reason"
  }
done

# Development/preflight lanes must remain usable while the changeset is incomplete.
GITHUB_WORKFLOW='Arthur Fast Preflight' bash "$ENTRY" >"$TMP/out" 2>"$TMP/err" || {
  cat "$TMP/out" "$TMP/err" >&2 || true
  fail "development preflight was incorrectly blocked"
}
grep -q 'PRODUCTION_ENTRY_GATE=SKIP' "$TMP/out" || fail "preflight skip marker missing"

# The checked-in state must remain deliberately non-production until all work is complete.
python3 - "$STATE" <<'PY'
import json, sys
state=json.load(open(sys.argv[1], encoding='utf-8'))
assert state['implementation_complete'] is False
assert state['frozen'] is False
assert state['build_class'] == 'DEVELOPMENT'
assert any(v != 'PASS' for v in state['tasks'].values())
PY

echo 'TEST_V43_WORKFLOW_HARD_GATE=PASS'
