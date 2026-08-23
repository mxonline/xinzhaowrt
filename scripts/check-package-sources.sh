#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
FEED_DIR="$SRC/package/feeds/xinzhao"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  luci-app-istorex
  luci-app-lucky
  luci-app-quickfile
  luci-app-quickstart
  luci-app-store
  luci-app-diskman
  luci-app-easytier
  easytier
  luci-app-mosdns
  mosdns
  v2dat
  v2ray-geodata
  luci-app-openclash
  luci-app-oaf
  oaf
  open-app-filter
)

missing=0
for pkg in "${required[@]}"; do
  path="$FEED_DIR/$pkg"
  if [[ ! -e "$path" || ! -f "$path/Makefile" ]]; then
    echo "MISSING_SOURCE: $pkg ($path)"
    missing=1
  fi
done

if (( missing )); then
  echo "ERROR: one or more selected external package sources are not installed correctly."
  exit 1
fi

assert_source() {
  local pkg="$1" expected="$2" actual
  actual="$(readlink -f "$FEED_DIR/$pkg" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "MISSING_SOURCE_PROVENANCE: $pkg (expected $expected, got ${actual:-<none>})"
    missing=1
  fi
}

# Verify the three iStore-related names without inventing luci-app-istore.
ISTORE_SOURCE="$SRC/.xinzhao-sources/istore"
KENZO_SOURCE="$SRC/.xinzhao-sources/kenzok8-openwrt-packages"
assert_source luci-app-store "$ISTORE_SOURCE/luci/luci-app-store"
assert_source luci-app-quickstart "$KENZO_SOURCE/luci-app-quickstart"
assert_source luci-app-istorex "$KENZO_SOURCE/luci-app-istorex"

if grep -Eq '^[[:space:]]*luci-app-istore([[:space:]]|$)' "$PROJECT_ROOT/config/required-plugins.txt" 2>/dev/null; then
  echo "ERROR: luci-app-istore is not a valid package name; use luci-app-store or luci-app-istorex."
  missing=1
fi

if (( missing )); then
  echo "ERROR: package source provenance validation failed."
  exit 1
fi

echo "PASS: selected external package sources are installed through feed xinzhao."
