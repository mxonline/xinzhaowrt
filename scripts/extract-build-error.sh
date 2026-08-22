#!/usr/bin/env bash
set -euo pipefail
LOG="${1:?Usage: $0 build.log}"
[[ -f "$LOG" ]] || { echo "No log: $LOG"; exit 1; }

echo "===== likely errors (first matches) ====="
grep -nEi '(^|[^[:alpha:]])(error:|ERROR:|failed to build|No rule to make target|recipe for target .* failed|Error [0-9]+|missing dependencies|Package .* is missing)' "$LOG" | head -n 80 || true

echo
echo "===== final 220 lines ====="
tail -n 220 "$LOG"
