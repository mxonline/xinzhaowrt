#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_DEBUG_DNS_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_debug_dns.lua}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash debug DNS source is missing: $SOURCE" >&2
  exit 1
}

resolve_line=$(grep -n 'resolve == "true"' "$SOURCE" | head -1 | cut -d: -f1 || true)
heavy_line=$(grep -n 'require "luci.sys"' "$SOURCE" | head -1 | cut -d: -f1 || true)
[[ -n "$resolve_line" && -n "$heavy_line" && "$resolve_line" -lt "$heavy_line" ]] || {
  echo 'FAIL: resolve mode still loads heavy LuCI modules before its fast path' >&2
  exit 1
}
grep -Eq 'io\.popen|nixio\.getaddrinfo' "$SOURCE" || {
  echo 'FAIL: debug DNS resolve mode has no lightweight resolver path' >&2
  exit 1
}

echo 'PASS: OpenClash debug DNS resolve mode avoids heavy LuCI/curl allocation'
