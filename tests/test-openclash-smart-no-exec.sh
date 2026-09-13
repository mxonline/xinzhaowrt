#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_core.sh}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash core updater source is missing: $SOURCE" >&2
  exit 1
}

if grep -Eq 'extract_err=\$\("\$TMP_FILE" -v' "$SOURCE"; then
  echo 'FAIL: Smart updater still executes the downloaded candidate during validation' >&2
  exit 1
fi
grep -Eq 'Smart candidate rejected before execution|Smart.*runtime validation.*fail-closed' "$SOURCE" || {
  echo 'FAIL: Smart updater has no explicit pre-execution fail-closed path' >&2
  exit 1
}

echo 'PASS: Smart core updater rejects untrusted candidates without executing them'
