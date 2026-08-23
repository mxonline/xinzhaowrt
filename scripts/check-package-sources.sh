#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
FEED_DIR="$SRC/package/feeds/xinzhao"
ISTORE_FEED_DIR="$SRC/package/feeds/istore"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  luci-app-istorex
  luci-app-lucky
  luci-app-quickfile
  luci-app-quickstart
  luci-app-adguardhome
  luci-app-autoreboot
  luci-app-firewall
  luci-app-package-manager
  luci-app-pbr
  luci-app-samba4
  luci-app-smartdns
  luci-app-sqm
  luci-app-ttyd
  luci-app-upnp
  luci-app-vlmcsd
  luci-app-wol
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
  [[ "$pkg" == "luci-app-store" ]] && path="$ISTORE_FEED_DIR/$pkg"
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

# Verify all three iStore-related names use one Kenzok8 source without
# inventing luci-app-istore.
KENZO_SOURCE="$SRC/.xinzhao-sources/kenzok8-openwrt-packages"
IMMORTAL_LUCI_SOURCE="$SRC/.xinzhao-sources/immortalwrt-luci"
assert_source luci-app-quickstart "$KENZO_SOURCE/luci-app-quickstart"
assert_source luci-app-istorex "$KENZO_SOURCE/luci-app-istorex"
assert_istore_source() {
  local pkg="$1" expected="$2" actual
  actual="$(readlink -f "$ISTORE_FEED_DIR/$pkg" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "MISSING_SOURCE_PROVENANCE: $pkg (expected $expected, got ${actual:-<none>})"
    missing=1
  fi
}
assert_istore_source luci-app-store "$KENZO_SOURCE/luci-app-store"
assert_istore_source luci-lib-taskd "$KENZO_SOURCE/luci-lib-taskd"
assert_istore_source luci-lib-xterm "$KENZO_SOURCE/luci-lib-xterm"
assert_istore_source taskd "$KENZO_SOURCE/taskd"
for pkg in luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol; do
  assert_source "$pkg" "$IMMORTAL_LUCI_SOURCE/applications/$pkg"
done
for pkg in luci-app-adguardhome luci-app-autoreboot luci-app-firewall luci-app-package-manager luci-app-pbr luci-app-samba4; do
  assert_source "$pkg" "$IMMORTAL_LUCI_SOURCE/applications/$pkg"
done

if grep -Eq '^[[:space:]]*luci-app-istore([[:space:]]|$)' "$PROJECT_ROOT/config/required-plugins.txt" 2>/dev/null; then
  echo "ERROR: luci-app-istore is not a valid package name; use luci-app-store or luci-app-istorex."
  missing=1
fi

if (( missing )); then
  echo "ERROR: package source provenance validation failed."
  exit 1
fi

echo "PASS: selected external package sources are installed through feed xinzhao."
