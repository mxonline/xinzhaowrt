#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(bash "$ROOT/scripts/v4-pipeline-dry-run.sh")"
grep -Fq 'Baseline Integrity: PASS' <<<"$output"
grep -Fq 'Routing: PASS' <<<"$output"
grep -Fq 'Toolchain: PASS' <<<"$output"
grep -Fq 'No Unexpected Build: PASS' <<<"$output"
grep -Fq 'No Flash: PASS' <<<"$output"
grep -Fq 'Case A: DOC_ONLY / NO_BUILD PASS' <<<"$output"
grep -Fq 'Case B: IMAGEBUILDER PASS' <<<"$output"
grep -Fq 'Case C: SDK_BUILD + IMAGEBUILDER PASS' <<<"$output"
grep -Fq 'Case D: FULL_BUILD PASS' <<<"$output"
printf '%s\n' 'PASS: v4 pipeline no-change dry run.'
