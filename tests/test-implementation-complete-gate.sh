#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/implementation-complete-gate.sh"

fail() { echo "IMPLEMENTATION_GATE_TEST: FAIL -- $*" >&2; exit 1; }
[[ -x "$GATE" ]] || fail 'implementation-complete-gate.sh is missing or not executable'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HEAD_SHA="1111111111111111111111111111111111111111"
CHANGESET_ID="arthur-ui-network-20260831"

write_state() {
  local implementation_complete="$1"
  local frozen="$2"
  local task_state="$3"
  local frozen_sha="$4"
  cat > "$TMP/state.json" <<JSON
{
  "schema_version": "4.3",
  "changeset_id": "$CHANGESET_ID",
  "state": "FROZEN",
  "implementation_complete": $implementation_complete,
  "frozen": $frozen,
  "frozen_source_sha": "$frozen_sha",
  "required_tasks": {
    "adguardhome_full_manager": "$task_state",
    "istoreos_original_quickstart": "$task_state",
    "wifi_real_connect_fix": "$task_state",
    "plugin_i18n": "$task_state",
    "argon_compatibility": "$task_state",
    "kucat_compatibility": "$task_state",
    "plugins_menu_cleanup": "$task_state",
    "baseline_regression": "$task_state"
  }
}
JSON
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"$TMP/$label.out" 2>&1; then
    cat "$TMP/$label.out" >&2
    fail "$label unexpectedly passed"
  fi
  grep -Fq 'IMPLEMENTATION_COMPLETE_GATE=FAIL' "$TMP/$label.out" || {
    cat "$TMP/$label.out" >&2
    fail "$label did not emit FAIL marker"
  }
}

write_state false false PENDING "$HEAD_SHA"
expect_fail incomplete env \
  CHANGESET_STATE_FILE="$TMP/state.json" \
  EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
  EXPECTED_SOURCE_SHA="$HEAD_SHA" \
  GATE_HEAD="$HEAD_SHA" \
  "$GATE"

write_state true true FAIL "$HEAD_SHA"
expect_fail failed_task env \
  CHANGESET_STATE_FILE="$TMP/state.json" \
  EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
  EXPECTED_SOURCE_SHA="$HEAD_SHA" \
  GATE_HEAD="$HEAD_SHA" \
  "$GATE"

write_state true true PASS "2222222222222222222222222222222222222222"
expect_fail wrong_sha env \
  CHANGESET_STATE_FILE="$TMP/state.json" \
  EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
  EXPECTED_SOURCE_SHA="$HEAD_SHA" \
  GATE_HEAD="$HEAD_SHA" \
  "$GATE"

write_state true true PASS "$HEAD_SHA"
env \
  CHANGESET_STATE_FILE="$TMP/state.json" \
  EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
  EXPECTED_SOURCE_SHA="$HEAD_SHA" \
  GATE_HEAD="$HEAD_SHA" \
  "$GATE" >"$TMP/pass.out" 2>&1 || {
    cat "$TMP/pass.out" >&2
    fail 'valid frozen state was rejected'
  }
grep -Fq 'IMPLEMENTATION_COMPLETE_GATE=PASS' "$TMP/pass.out" || fail 'PASS marker missing'
grep -Fq 'CHANGESET_FREEZE=PASS' "$TMP/pass.out" || fail 'freeze marker missing'

echo 'IMPLEMENTATION_GATE_TEST=PASS'
