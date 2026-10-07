#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_core.sh}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash source is missing: $SOURCE" >&2
  exit 1
}

require_fixed() {
  local pattern="$1"
  grep -Eq "$pattern" "$SOURCE" || {
    echo "FAIL: missing OpenClash updater safety contract: $pattern" >&2
    exit 1
  }
}

require_absent() {
  local pattern="$1"
  ! grep -Eq "$pattern" "$SOURCE" || {
    echo "FAIL: forbidden OpenClash updater pattern remains: $pattern" >&2
    exit 1
  }
}

require_fixed 'command[[:space:]]+-v[[:space:]]+flock'
require_fixed 'flock[[:space:]]+-x[[:space:]]+872([^[:alnum:]_]|$)'
require_fixed 'RUN_ROOT="/tmp/openclash-core-update"'
require_fixed 'RUN_DIR="\$RUN_ROOT/\$\$"'
require_fixed 'mkdir[[:space:]]+(-p[[:space:]]+)?"\$RUN_DIR"'
require_fixed 'tar[[:space:]].*-C[[:space:]]+"\$RUN_DIR"'
require_fixed 'mv[[:space:]]+"\$RUN_DIR/clash"'
require_fixed 'rm[[:space:]]+-rf[[:space:]]+"\$RUN_DIR"'

require_absent 'rm[[:space:]]+-rf[[:space:]]+"/tmp/lock/openclash_core\.lock"'
require_absent 'DOWNLOAD_FILE="/tmp/clash_meta\.tar\.gz"'
require_absent 'tar[[:space:]].*-C[[:space:]]+/tmp([[:space:]]|$)'
require_absent 'TMP_FILE="\$\{TARGET_CORE_PATH\}\.new\.\$\$"'

echo "PASS: OpenClash updater has validated flock, stable lock lifecycle, and private per-process temporary paths"
