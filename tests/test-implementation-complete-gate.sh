#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/implementation-complete-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "TEST_FAIL: $*" >&2; exit 1; }
expect_fail() {
  local label="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    fail "$label unexpectedly passed"
  fi
}
expect_pass() {
  local label="$1"; shift
  if ! "$@" >"$TMP/out" 2>"$TMP/err"; then
    cat "$TMP/out" "$TMP/err" >&2 || true
    fail "$label unexpectedly failed"
  fi
}

make_state() {
  local file="$1" implementation_complete="$2" frozen="$3" task_state="$4" changeset_id="$5" source_sha="$6"
  cat >"$file" <<JSON
{
  "changeset_id": "$changeset_id",
  "source_sha": "$source_sha",
  "implementation_complete": $implementation_complete,
  "frozen": $frozen,
  "tasks": {
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

[[ -x "$GATE" ]] || fail "gate script missing or not executable: $GATE"

expect_fail "missing state" "$GATE" "$TMP/missing.json"

make_state "$TMP/pending.json" false false PENDING arthur-v43 abc123
expect_fail "pending tasks" "$GATE" "$TMP/pending.json"

grep -q 'TASK_NOT_PASS' "$TMP/err" || fail "pending task failure did not identify TASK_NOT_PASS"

make_state "$TMP/not-complete.json" false true PASS arthur-v43 abc123
expect_fail "implementation false" "$GATE" "$TMP/not-complete.json"
grep -q 'IMPLEMENTATION_COMPLETE_FALSE' "$TMP/err" || fail "missing implementation-complete failure reason"

make_state "$TMP/not-frozen.json" true false PASS arthur-v43 abc123
expect_fail "frozen false" "$GATE" "$TMP/not-frozen.json"
grep -q 'CHANGESET_NOT_FROZEN' "$TMP/err" || fail "missing frozen failure reason"

make_state "$TMP/good.json" true true PASS arthur-v43 abc123
expect_fail "changeset mismatch" "$GATE" "$TMP/good.json" other-id
grep -q 'CHANGESET_ID_MISMATCH' "$TMP/err" || fail "missing changeset mismatch reason"

expect_fail "source sha mismatch" "$GATE" "$TMP/good.json" arthur-v43 deadbeef
grep -q 'SOURCE_SHA_MISMATCH' "$TMP/err" || fail "missing source sha mismatch reason"

expect_pass "valid frozen changeset" "$GATE" "$TMP/good.json" arthur-v43 abc123
grep -q 'IMPLEMENTATION_COMPLETE_GATE=PASS' "$TMP/out" || fail "PASS marker missing"

echo 'TEST_IMPLEMENTATION_COMPLETE_GATE=PASS'
