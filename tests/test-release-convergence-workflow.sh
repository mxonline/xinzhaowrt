#!/usr/bin/env bash
set -Eeuo pipefail

workflow='.github/workflows/arthur-update-v3.yml'
policy='production/fast-safe-release-policy.json'
checker='scripts/check-release-convergence.py'

[[ -f "$workflow" ]] || { echo "FAIL: missing $workflow" >&2; exit 1; }
[[ -f "$policy" ]] || { echo "FAIL: missing $policy" >&2; exit 1; }
[[ -f "$checker" ]] || { echo "FAIL: missing $checker" >&2; exit 1; }

grep -Fq 'Enforce release convergence before build' "$workflow" || { echo 'FAIL: production workflow must enforce convergence before Build Candidate.' >&2; exit 1; }
grep -Fq 'python3 scripts/check-release-convergence.py' "$workflow" || { echo 'FAIL: production workflow must call the shared convergence checker.' >&2; exit 1; }

gate_line="$(grep -nF 'Enforce release convergence before build' "$workflow" | head -1 | cut -d: -f1)"
build_line="$(grep -nF 'Build Candidate from locked sources' "$workflow" | head -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$build_line" && "$gate_line" -lt "$build_line" ]] || { echo 'FAIL: convergence gate must execute before the expensive build step.' >&2; exit 1; }

grep -Fq 'failure_set_state' "$checker" || { echo 'FAIL: checker must require final failure-set state.' >&2; exit 1; }
grep -Fq 'RESOLVED' "$checker" || { echo 'FAIL: checker must require RESOLVED failure set.' >&2; exit 1; }
grep -Fq 'rootfs_offline_passed' "$checker" || { echo 'FAIL: checker must require rootfs offline acceptance.' >&2; exit 1; }
grep -Fq 'contract_gap_state' "$checker" || { echo 'FAIL: checker must reject unresolved contract gaps.' >&2; exit 1; }
grep -Fq 'firmware_input_fingerprint' "$checker" || { echo 'FAIL: checker must bind convergence evidence to firmware inputs.' >&2; exit 1; }

grep -Fq 'failure_set_required_before_build' "$policy" || { echo 'FAIL: machine policy must state failure-set-before-build requirement.' >&2; exit 1; }
grep -Fq 'cancel_active_build_if_failure_set_unresolved' "$policy" || { echo 'FAIL: machine policy must require cancellation of premature active builds.' >&2; exit 1; }
grep -Fq 'clean_postflash_required_for_release' "$policy" || { echo 'FAIL: machine policy must require clean PostFlash evidence.' >&2; exit 1; }

echo 'PASS: release convergence gate is wired before production build.'
