#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/files/etc/uci-defaults/99-xinzhao-defaults"

grep -qF 'XINZHAO_FIRSTBOOT_LOG' "$FILE" || { echo 'ERROR: durable first-boot log path missing'; exit 1; }
grep -qF 'log_file' "$FILE" || { echo 'ERROR: first-boot log file is not used'; exit 1; }
grep -qF '>> "$log_file"' "$FILE" || { echo 'ERROR: first-boot stages are not appended to durable log'; exit 1; }
grep -qF "log 'FIRSTBOOT_START' || fail log_write_start" "$FILE" || { echo 'ERROR: start log write is not checked'; exit 1; }
grep -qF "log 'FIRSTBOOT_COMPLETE' || fail log_write_complete" "$FILE" || { echo 'ERROR: completion log write is not checked'; exit 1; }
grep -qF 'FIRSTBOOT_FAIL stage=' "$FILE" || { echo 'ERROR: failure stage evidence missing'; exit 1; }

echo 'FIRSTBOOT_OBSERVABILITY_STATIC_CHECK: PASS'
