#!/usr/bin/env bash
set -Eeuo pipefail

workflow='.github/workflows/arthur-update-v3.yml'
policy='production/fast-safe-release-policy.json'
checker='scripts/check-release-convergence.py'
fingerprinter='scripts/get-firmware-input-fingerprint.sh'

[[ -f "$workflow" ]] || { echo "FAIL: missing $workflow" >&2; exit 1; }
[[ -f "$policy" ]] || { echo "FAIL: missing $policy" >&2; exit 1; }
[[ -f "$checker" ]] || { echo "FAIL: missing $checker" >&2; exit 1; }
[[ -f "$fingerprinter" ]] || { echo "FAIL: missing $fingerprinter" >&2; exit 1; }

grep -Fq 'Validate durable v3 convergence request' "$workflow" || { echo 'FAIL: production workflow must validate the durable request before accepting convergence inputs.' >&2; exit 1; }
grep -Fq 'production/v3-request.json?ref=main' "$workflow" || { echo 'FAIL: production workflow must read authoritative main:v3-request.json.' >&2; exit 1; }
grep -Fq 'GITHUB_REF_NAME' "$workflow" || { echo 'FAIL: production workflow must bind durable source_ref to the actual immutable workflow ref.' >&2; exit 1; }
grep -Fq 'GITHUB_SHA' "$workflow" || { echo 'FAIL: production workflow must bind durable source_sha to the actual checked-out commit.' >&2; exit 1; }
grep -Fq 'V3_REQUEST_CONVERGENCE_BINDING=PASS' "$workflow" || { echo 'FAIL: production workflow must expose durable request binding evidence.' >&2; exit 1; }

request_line="$(grep -nF 'Validate durable v3 convergence request' "$workflow" | head -1 | cut -d: -f1)"
gate_line="$(grep -nF 'Enforce release convergence before build' "$workflow" | head -1 | cut -d: -f1)"
build_line="$(grep -nF 'Build Candidate from locked sources' "$workflow" | head -1 | cut -d: -f1)"
[[ -n "$request_line" && -n "$gate_line" && -n "$build_line" && "$request_line" -lt "$gate_line" && "$gate_line" -lt "$build_line" ]] || { echo 'FAIL: durable request binding and convergence gate must both execute before the expensive build step.' >&2; exit 1; }

grep -Fq 'python3 scripts/check-release-convergence.py' "$workflow" || { echo 'FAIL: production workflow must call the shared convergence checker.' >&2; exit 1; }
grep -Fq 'failure_set_state' "$checker" || { echo 'FAIL: checker must require final failure-set state.' >&2; exit 1; }
grep -Fq 'RESOLVED' "$checker" || { echo 'FAIL: checker must require RESOLVED failure set.' >&2; exit 1; }
grep -Fq 'rootfs_offline_passed' "$checker" || { echo 'FAIL: checker must require rootfs offline acceptance.' >&2; exit 1; }
grep -Fq 'contract_gap_state' "$checker" || { echo 'FAIL: checker must reject unresolved contract gaps.' >&2; exit 1; }
grep -Fq 'firmware_input_fingerprint' "$checker" || { echo 'FAIL: checker must bind convergence evidence to firmware inputs.' >&2; exit 1; }

grep -Fq 'REF="${1:-HEAD}"' "$fingerprinter" || { echo 'FAIL: firmware fingerprint helper must support an explicit immutable source ref.' >&2; exit 1; }
grep -Fq 'git ls-tree -r --name-only "$REF"' "$fingerprinter" || { echo 'FAIL: source-ref fingerprint must enumerate files from that ref, not the moving worktree.' >&2; exit 1; }
grep -Fq 'git rev-parse "$REF:$path"' "$fingerprinter" || { echo 'FAIL: source-ref fingerprint must bind exact Git blobs at the immutable ref.' >&2; exit 1; }

grep -Fq 'failure_set_required_before_build' "$policy" || { echo 'FAIL: machine policy must state failure-set-before-build requirement.' >&2; exit 1; }
grep -Fq 'cancel_active_build_if_failure_set_unresolved' "$policy" || { echo 'FAIL: machine policy must require cancellation of premature active builds.' >&2; exit 1; }
grep -Fq 'clean_postflash_required_for_release' "$policy" || { echo 'FAIL: machine policy must require clean PostFlash evidence.' >&2; exit 1; }

echo 'PASS: release convergence gate is wired and bound to the durable v3 request before production build.'
