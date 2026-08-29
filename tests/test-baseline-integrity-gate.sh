#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/baseline-integrity-gate.sh"

output="$(bash "$GATE")"
grep -Fq 'BASELINE_INTEGRITY=PASS' <<<"$output"
grep -Fq 'TAG_TARGET=PASS' <<<"$output"
grep -Fq 'FIRMWARE_SHA256=PASS' <<<"$output"
grep -Fq 'TOOLCHAIN_PROVENANCE=PASS' <<<"$output"
grep -Fq 'PLUGINS_22=PASS' <<<"$output"
printf '%s\n' 'PASS: baseline integrity gate.'
