#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${PYTHON_BIN:?PYTHON_BIN must point to Python 3.10 or newer}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/diagnostics" "$tmp/analyzed"
cp "$root/tests/fixtures/failure-classifier/run-35597970023/error-summary.txt" "$tmp/diagnostics/build.log"

ANALYZE_ERROR_OUT_DIR="$tmp/analyzed" bash "$root/scripts/analyze-error.sh" "$tmp/diagnostics/build.log"
grep -Fq 'Failure stage: Final rootfs/package verifier gate' "$tmp/analyzed/error-summary.txt"
grep -Fq 'First real error: 119: FINAL_ROOTFS_OPENCLASH_CORE=FAIL' "$tmp/analyzed/error-summary.txt"

"$python_bin" "$root/scripts/failure-fingerprint.py" "$tmp/diagnostics" --output "$tmp/analyzed/failure-fingerprint.json" > "$tmp/fingerprint.out"
grep -Fq '"kind": "final-verifier-gate"' "$tmp/analyzed/failure-fingerprint.json"
grep -Fq '"stage": "Final rootfs/package verifier gate"' "$tmp/analyzed/failure-fingerprint.json"
grep -Fq 'FINAL_ROOTFS_OPENCLASH_CORE=FAIL' "$tmp/analyzed/failure-fingerprint.json"
grep -Fq 'test-failure-classifier.sh' "$root/scripts/verify-project.sh"
echo 'FAILURE_CLASSIFIER_REAL_RUN_35597970023=PASS'
