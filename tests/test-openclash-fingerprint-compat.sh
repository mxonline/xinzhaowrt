#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_INIT_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/etc/init.d/openclash}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash init source is missing: $SOURCE" >&2
  exit 1
}

grep -Eq 'sanitize_legacy_fingerprint' "$SOURCE" || {
  echo 'FAIL: OpenClash does not sanitize the removed global-client-fingerprint key' >&2
  exit 1
}
grep -Eq 'global-client-fingerprint' "$SOURCE" || {
  echo 'FAIL: compatibility rule for global-client-fingerprint is missing' >&2
  exit 1
}

echo 'PASS: OpenClash removes the legacy global-client-fingerprint key before YAML validation'
