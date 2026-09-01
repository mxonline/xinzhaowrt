#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bash scripts/acceptance-contract-gate.sh >/tmp/xinzhao-acceptance-contract-gate.log
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  echo 'ACCEPTANCE_CONTRACT_TEST: FAIL -- no working Python interpreter' >&2
  exit 1
fi
"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path
data = json.loads(Path('output/acceptance-contract-gate.json').read_text(encoding='utf-8'))
assert data['status'] == 'PASS'
assert data['all_requirements_covered'] is True
assert data['static_acceptance_pass'] is True
assert data['unknown'] == 0
PY
grep -Fxq 'ALL_REQUIREMENTS_COVERED=true' /tmp/xinzhao-acceptance-contract-gate.log
grep -Fxq 'STATIC_ACCEPTANCE_PASS=true' /tmp/xinzhao-acceptance-contract-gate.log
grep -Fxq 'UNKNOWN=0' /tmp/xinzhao-acceptance-contract-gate.log
echo 'ACCEPTANCE_CONTRACT_TEST: PASS'
