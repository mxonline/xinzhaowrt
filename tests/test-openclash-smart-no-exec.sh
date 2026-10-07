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
grep -Eq 'validate_candidate\(\)' "$SOURCE" || {
  echo 'FAIL: Smart updater has no explicit candidate validation function' >&2
  exit 1
}
grep -Eq 'timeout[[:space:]]+10[[:space:]]+"\$candidate"[[:space:]]+-v' "$SOURCE" || {
  echo 'FAIL: Smart candidate validation has no bounded runtime check' >&2
  exit 1
}
grep -Eq '\[ -x "\$candidate" \]' "$SOURCE" || {
  echo 'FAIL: Smart candidate validation does not require an executable candidate' >&2
  exit 1
}
grep -Eq 'extract_err=\$\(validate_candidate "\$TMP_FILE"\)' "$SOURCE" || {
  echo 'FAIL: Smart updater does not gate replacement on candidate validation' >&2
  exit 1
}

echo 'PASS: Smart core updater validates candidates with bounded fail-closed checks before replacement'
