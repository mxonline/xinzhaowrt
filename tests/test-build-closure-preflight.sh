#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build.sh"
CONTROLLER="$ROOT/scripts/ci-controller-v3.ps1"
WORKFLOW="$ROOT/.github/workflows/arthur-fast-preflight.yml"

for file in "$BUILD" "$CONTROLLER" "$WORKFLOW"; do
  [[ -s "$file" ]] || { echo "FAIL: missing $file" >&2; exit 1; }
done

grep -Fq 'BUILD_CLOSURE_ONLY' "$BUILD" || { echo 'FAIL: build.sh has no closure-only mode' >&2; exit 1; }
grep -Fq 'BUILD_CLOSURE_PREFLIGHT=PASS' "$BUILD" || { echo 'FAIL: build.sh has no closure PASS marker' >&2; exit 1; }

python3 - "$BUILD" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
marker = text.find('BUILD_CLOSURE_PREFLIGHT=PASS')
download = text.find('make download')
compile_ = text.find('Compile firmware')
if marker < 0 or download < 0 or compile_ < 0:
    raise SystemExit('FAIL: unable to locate closure/download/compile markers')
if not (marker < download < compile_):
    raise SystemExit('FAIL: closure mode must exit before source download and firmware compile')
PY

grep -Fq 'build_closure:' "$WORKFLOW" || { echo 'FAIL: Fast Preflight workflow has no build_closure dispatch input' >&2; exit 1; }
python3 - "$WORKFLOW" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
# Accept either shell assignment or YAML env form; both execute build.sh with closure-only=1.
if not (re.search(r'BUILD_CLOSURE_ONLY\s*=\s*["\x27]?1', text) or re.search(r'BUILD_CLOSURE_ONLY\s*:\s*["\x27]1["\x27]', text)):
    raise SystemExit('FAIL: Fast Preflight workflow does not run exact build.sh closure mode')
if './scripts/build.sh' not in text:
    raise SystemExit('FAIL: Fast Preflight closure job does not execute build.sh')
PY
grep -Fq 'Arthur-build-closure-' "$WORKFLOW" || { echo 'FAIL: build closure diagnostics are not persisted' >&2; exit 1; }

grep -Fq 'function Invoke-BuildClosurePreflight' "$CONTROLLER" || { echo 'FAIL: controller has no unattended closure orchestration' >&2; exit 1; }
grep -Fq 'build_closure=true' "$CONTROLLER" || { echo 'FAIL: controller does not explicitly dispatch closure mode' >&2; exit 1; }
grep -Fq 'BUILD_CLOSURE_PREFLIGHT=PASS' "$CONTROLLER" || { echo 'FAIL: controller does not require closure PASS before replacement Candidate' >&2; exit 1; }
grep -Fq 'BUILD_CLOSURE_FAILED_CONTINUE_REPAIR' "$CONTROLLER" || { echo 'FAIL: failed closure does not remain in repair lane' >&2; exit 1; }
grep -Fq 'BUILD_CLOSURE_PASS_ALLOW_CANDIDATE' "$CONTROLLER" || { echo 'FAIL: controller lacks explicit closure-pass Candidate boundary' >&2; exit 1; }
grep -Fq 'Invoke-BuildClosurePreflight -RequestedMode $RequestedMode' "$CONTROLLER" || { echo 'FAIL: failed-Candidate path does not invoke closure before replacement Candidate' >&2; exit 1; }

python3 - "$CONTROLLER" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
start = text.find('function Process-V3Run')
if start < 0:
    raise SystemExit('FAIL: Process-V3Run missing')
body = text[start:]
needle = 'Invoke-BuildClosurePreflight -RequestedMode $RequestedMode'
closure = body.rfind(needle)
dispatch = body.rfind('$currentRunId = Start-V3Run -RequestedMode $RequestedMode')
if closure < 0 or dispatch < 0 or closure > dispatch:
    raise SystemExit('FAIL: closure PASS must be required immediately before the failed-run replacement Candidate dispatch')

# A repair-round circuit breaker is allowed to reset counters, but it must not
# dispatch a replacement Candidate before the repair-evidence/closure lane.
circuit = body.find('if ($round -ge $MaxRepairRounds)')
evidence = body.find('$repairEvidenceRunId = $currentRunId')
if circuit < 0 or evidence < 0 or circuit >= evidence:
    raise SystemExit('FAIL: failure-path circuit breaker/evidence boundary missing')
if '$currentRunId = Start-V3Run -RequestedMode $RequestedMode' in body[circuit:evidence]:
    raise SystemExit('FAIL: circuit breaker bypasses build closure and starts Candidate directly')
PY

echo 'PASS: Arthur source/feed/package/defconfig closure is required before any failed-run replacement Candidate.'
