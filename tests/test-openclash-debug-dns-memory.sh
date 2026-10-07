#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEED_CHECK_ROOT="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
SOURCE="${OPENCLASH_DEBUG_DNS_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_debug_dns.lua}"
WATCHDOG_SOURCE="${OPENCLASH_WATCHDOG_SOURCE:-$FEED_CHECK_ROOT/.xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_watchdog.sh}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: OpenClash debug DNS source is missing: $SOURCE" >&2
  exit 1
}
[[ -f "$WATCHDOG_SOURCE" ]] || {
  echo "FAIL: OpenClash watchdog source is missing: $WATCHDOG_SOURCE" >&2
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
grep -Eq '^#!/bin/sh$|flock -n 9' "$SOURCE" || {
  echo 'FAIL: debug DNS executable has no pre-interpreter single-flight guard' >&2
  exit 1
}
grep -Eq 'gsub\('\''\^"\(\.\*\)"\$'\'', '\''%1'\''\)' "$SOURCE" || {
  echo 'FAIL: debug DNS does not normalize watchdog escaped arguments' >&2
  exit 1
}
grep -Eq 'MemAvailable:|MemAvailable' "$WATCHDOG_SOURCE" || {
  echo 'FAIL: watchdog has no low-memory guard before optional DNS probing' >&2
  exit 1
}
grep -Eq '131072|128' "$WATCHDOG_SOURCE" || {
  echo 'FAIL: watchdog low-memory guard has no 128 MiB threshold' >&2
  exit 1
}

echo 'PASS: OpenClash debug DNS resolve mode avoids heavy allocation and low-memory watchdog fork'
