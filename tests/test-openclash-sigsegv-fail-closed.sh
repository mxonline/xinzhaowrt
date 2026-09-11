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

grep -Eq 'validate_result[[:space:]]*=' "$SOURCE" || {
  echo 'FAIL: candidate validation exit status is not captured' >&2
  exit 1
}
grep -Eq 'validate_result.*-[[:space:]]*ge[[:space:]]+128|validate_result.*-[[:space:]]*gt[[:space:]]+127' "$SOURCE" || {
  echo 'FAIL: signal-terminated candidate is not classified as fatal' >&2
  exit 1
}
grep -Eq 'fatal_candidate|Candidate Rejected|candidate.*signal' "$SOURCE" || {
  echo 'FAIL: signal-terminated candidate is not explicitly rejected' >&2
  exit 1
}

echo 'PASS: OpenClash Smart candidate SIGSEGV is fail-closed'
