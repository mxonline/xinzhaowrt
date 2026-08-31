#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "PIPELINE_V4_3_TEST=FAIL -- $*" >&2; exit 1; }

STATE="$ROOT/production/current-changeset.json"
POLICY="$ROOT/production/pipeline-policy.json"
GATE="$ROOT/scripts/implementation-complete-gate.sh"
CHANGESET_GATE="$ROOT/scripts/check-changeset-complete.sh"
FAST_TEST="$ROOT/tests/test-fast-candidate-workflow.sh"
VERIFY="$ROOT/scripts/verify-project.sh"
THEME_WF="$ROOT/.github/workflows/arthur-theme-candidate.yml"
FAST_WF="$ROOT/.github/workflows/arthur-fast-candidate.yml"
BUILD_WF="$ROOT/.github/workflows/build.yml"

for file in "$STATE" "$POLICY" "$GATE" "$CHANGESET_GATE" "$FAST_TEST" "$VERIFY" "$THEME_WF" "$FAST_WF" "$BUILD_WF"; do
  [[ -f "$file" ]] || fail "missing $file"
done

grep -Fq '"schema_version": "4.3"' "$STATE" || fail 'changeset schema is not v4.3'
grep -Fq '"implementation_complete": false' "$STATE" || fail 'current changeset must start fail-closed'
grep -Fq '"frozen": false' "$STATE" || fail 'current changeset must start unfrozen'
grep -Fq '"allow_candidate_build": false' "$STATE" || fail 'candidate build must start disabled'
grep -Fq '"production_terminal_state": "PRODUCTION_RELEASED"' "$STATE" || fail 'terminal state missing'

grep -Fq 'IMPLEMENTATION_COMPLETE_GATE=FAIL' "$GATE" || fail 'hard gate does not fail closed'
grep -Fq 'CANDIDATE_ELIGIBLE=NO' "$GATE" || fail 'hard gate does not deny candidates on failure'
grep -Fq 'frozen_source_sha' "$GATE" || fail 'source SHA binding missing'
grep -Fq 'required tasks not PASS' "$GATE" || fail 'required-task validation missing'
grep -Fq 'candidate_policy.allow_candidate_build' "$GATE" || fail 'candidate policy validation missing'

grep -Fq 'bash ./scripts/implementation-complete-gate.sh' "$CHANGESET_GATE" || fail 'changeset gate bypasses hard gate'
grep -Fq 'bash "$root/scripts/check-changeset-complete.sh"' "$FAST_TEST" || fail 'fast candidate workflow is not hard-gated before SDK build'
grep -Fq 'Arthur Fast Candidate SDK and ImageBuilder' "$FAST_TEST" || fail 'fast candidate workflow identity check missing'
grep -Fq 'Build XinZhaoWrt Arthur' "$VERIFY" || fail 'generic Arthur build workflow identity check missing'
grep -Fq 'bash ./scripts/check-changeset-complete.sh' "$VERIFY" || fail 'generic Arthur build bypasses hard gate'

# Theme candidate already invokes check-changeset-complete.sh before its SDK build.
grep -Fq './scripts/check-changeset-complete.sh' "$THEME_WF" || fail 'theme candidate bypasses changeset hard gate'
# Fast candidate executes test-fast-candidate-workflow.sh before SDK_BUILD; that test delegates to the hard gate in Actions.
grep -Fq './tests/test-fast-candidate-workflow.sh' "$FAST_WF" || fail 'fast candidate does not execute its hard-gate test before SDK build'
# Generic build executes verify-project.sh before build dependencies/build work.
grep -Fq './scripts/verify-project.sh' "$BUILD_WF" || fail 'generic build does not execute project/hard gate'

grep -Fq '"mode": "BATCHED_CHANGESET"' "$POLICY" || fail 'batched changeset policy missing'
grep -Fq '"fail_closed": true' "$POLICY" || fail 'candidate hard gate is not fail-closed'
grep -Fq 'WIFI_CLIENT_CONNECT_GATE' "$POLICY" || fail 'real Wi-Fi connection gate missing'
grep -Fq '"adguardhome_final_state": "DISABLED"' "$POLICY" || fail 'AdGuard Home final disabled policy missing'

echo 'PIPELINE_V4_3_TEST=PASS'
