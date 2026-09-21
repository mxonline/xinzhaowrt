#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/failure-classify/run-35597970023/build.log"
OUT="$ROOT/output/logs"
rm -f "$OUT/error-summary.txt" "$OUT/failure-report.txt" "$OUT/error-context.txt"
GITHUB_RUN_ID=35597970023 GITHUB_SHA=87ee88dcdfaab3191540a6722bd75a1a4fbad356 \
  bash "$ROOT/scripts/analyze-error.sh" "$FIXTURE" "$ROOT/tests/fixtures/failure-classify/run-35597970023/no-feed-error.txt"
grep -Fq 'Failure stage: final rootfs / acceptance gate' "$OUT/error-summary.txt"
grep -Fq 'FINAL_ROOTFS_OPENCLASH_CORE=FAIL' "$OUT/error-summary.txt"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$OUT/error-summary.txt" "$tmp/error-summary.txt"
cp "$FIXTURE" "$tmp/build.log"
python3 "$ROOT/scripts/failure-fingerprint.py" "$tmp" --output "$tmp/fingerprint.json" >/dev/null
python3 - "$tmp/fingerprint.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
assert d['stage']=='final rootfs / acceptance gate', d
assert d['kind']=='final-gate', d
assert any('FINAL_ROOTFS_OPENCLASH_CORE=FAIL' in s for s in d['signals']), d
PY
echo 'FAILURE_CLASSIFIER_REAL_RUN_35597970023=PASS'
