#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${OPENCLASH_WATCHDOG_SOURCE:-$ROOT/work/immortalwrt/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_watchdog.sh}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash watchdog source is missing: $SOURCE" >&2
  exit 1
}

grep -Eq 'threads[[:space:]]*=[[:space:]]*\(1\.\.\[1, queue\.size\]\.min\)' "$SOURCE" || {
  echo 'FAIL: watchdog DNS probes must be single-flight to avoid fork/ENOMEM amplification' >&2
  exit 1
}

if grep -Eq 'threads[[:space:]]*=[[:space:]]*\(1\.\.\[10, queue\.size\]\.min\)' "$SOURCE"; then
  echo 'FAIL: watchdog still permits ten concurrent DNS helper forks' >&2
  exit 1
fi

echo 'PASS: OpenClash watchdog DNS helper is single-flight'
