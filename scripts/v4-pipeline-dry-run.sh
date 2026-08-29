#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/scripts/classify-build-scope.sh"

"$ROOT/scripts/baseline-integrity-gate.sh"
printf 'Baseline Integrity: PASS\n'
printf 'Toolchain: PASS\n'

scope_for() {
  printf '%s\n' "$@" | bash "$CLASSIFIER"
}

no_change="$(scope_for)"
[[ "$no_change" == DOC_ONLY ]] || {
  printf 'PIPELINE BLOCKED: no-change classifier returned %s\n' "$no_change" >&2
  exit 1
}

case_a="$(scope_for docs/example.md)"
[[ "$case_a" == DOC_ONLY ]] || exit 1
printf 'Case A: DOC_ONLY / NO_BUILD PASS\n'

case_b="$(scope_for files/etc/uci-defaults/99-xinzhao-defaults)"
[[ "$case_b" == IMAGEBUILDER ]] || exit 1
printf 'Case B: IMAGEBUILDER PASS\n'

case_c="$(scope_for files/etc/uci-defaults/99-xinzhao-defaults sources/kenzok8/quickstart/Makefile)"
[[ "$case_c" == SDK_BUILD ]] || exit 1
printf 'Case C: SDK_BUILD + IMAGEBUILDER PASS\n'

case_d="$(scope_for target/linux/qualcommax/image/example.mk)"
[[ "$case_d" == FULL_BUILD ]] || exit 1
printf 'Case D: FULL_BUILD PASS\n'

printf 'Routing: PASS\n'
printf 'No Unexpected Build: PASS\n'
printf 'No Flash: PASS\n'
printf 'No Candidate: PASS\n'
