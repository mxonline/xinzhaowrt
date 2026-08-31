#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/implementation-complete-gate.sh"

fail() { echo "IMPLEMENTATION_GATE_TEST: FAIL -- $*" >&2; exit 1; }
[[ -f "$GATE" ]] || fail 'implementation-complete-gate.sh is missing'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CANDIDATE_SHA="1111111111111111111111111111111111111111"
IMPLEMENTATION_SHA="0000000000000000000000000000000000000000"
CHANGESET_ID="arthur-ui-network-20260831"
FREEZE_FILE="production/current-changeset.json"

write_state() {
  local implementation_complete="$1"
  local frozen="$2"
  local task_state="$3"
  local frozen_source_sha="$4"
  local allow_candidate="$5"
  cat > "$TMP/state.json" <<JSON
{
  "schema_version": "4.3",
  "changeset_id": "$CHANGESET_ID",
  "state": "FROZEN",
  "implementation_complete": $implementation_complete,
  "frozen": $frozen,
  "frozen_source_sha": "$frozen_source_sha",
  "required_tasks": {
    "adguardhome_full_manager": "$task_state",
    "istoreos_original_quickstart": "$task_state",
    "wifi_real_connect_fix": "$task_state",
    "plugin_i18n": "$task_state",
    "argon_compatibility": "$task_state",
    "kucat_compatibility": "$task_state",
    "plugins_menu_cleanup": "$task_state",
    "baseline_regression": "$task_state"
  },
  "candidate_policy": {
    "allow_candidate_build": $allow_candidate,
    "allow_flash": false,
    "allow_real_device_verify": false,
    "allow_release": false
  },
  "production_terminal_state": "PRODUCTION_RELEASED"
}
JSON
}

run_gate() {
  env \
    CHANGESET_STATE_FILE="$TMP/state.json" \
    EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
    EXPECTED_CANDIDATE_SHA="$CANDIDATE_SHA" \
    EXPECTED_IMPLEMENTATION_SHA="$IMPLEMENTATION_SHA" \
    GATE_HEAD="$CANDIDATE_SHA" \
    GATE_PARENT="$IMPLEMENTATION_SHA" \
    GATE_FREEZE_FILES="$FREEZE_FILE" \
    bash "$GATE"
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

write_state false false PENDING "$IMPLEMENTATION_SHA" false
expect_fail incomplete run_gate

write_state true true FAIL "$IMPLEMENTATION_SHA" true
expect_fail failed_task run_gate

write_state true true PASS "2222222222222222222222222222222222222222" true
expect_fail wrong_parent run_gate

write_state true true PASS "$IMPLEMENTATION_SHA" false
expect_fail policy_closed run_gate

write_state true true PASS "$IMPLEMENTATION_SHA" true
expect_fail dirty_freeze env \
  CHANGESET_STATE_FILE="$TMP/state.json" \
  EXPECTED_CHANGESET_ID="$CHANGESET_ID" \
  EXPECTED_CANDIDATE_SHA="$CANDIDATE_SHA" \
  EXPECTED_IMPLEMENTATION_SHA="$IMPLEMENTATION_SHA" \
  GATE_HEAD="$CANDIDATE_SHA" \
  GATE_PARENT="$IMPLEMENTATION_SHA" \
  GATE_FREEZE_FILES=$'production/current-changeset.json\nfiles/etc/config/wireless' \
  bash "$GATE"

# Candidate authorization is sufficient here. Flash/verify/release remain false
# and are controlled by downstream gates after the candidate exists.
run_gate >"$TMP/pass.out" 2>&1 || {
  cat "$TMP/pass.out" >&2
  fail 'valid state-only freeze commit was rejected'
}
grep -Fq 'IMPLEMENTATION_COMPLETE_GATE=PASS' "$TMP/pass.out" || fail 'PASS marker missing'
grep -Fq 'CHANGESET_FREEZE=PASS' "$TMP/pass.out" || fail 'freeze marker missing'
grep -Fq 'CANDIDATE_ELIGIBLE=YES' "$TMP/pass.out" || fail 'candidate eligibility marker missing'
grep -Fq "FROZEN_IMPLEMENTATION_SHA=$IMPLEMENTATION_SHA" "$TMP/pass.out" || fail 'implementation SHA marker missing'
grep -Fq "FROZEN_CANDIDATE_SHA=$CANDIDATE_SHA" "$TMP/pass.out" || fail 'candidate SHA marker missing'

echo 'IMPLEMENTATION_GATE_TEST=PASS'
