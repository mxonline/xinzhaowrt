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
  if [[ "$pkg" == "luci-app-store" ]]; then
    # 同一份 Kenzok8 assembled feed 可能被 OpenWrt 注册为 xinzhao，
    # 也可能因兼容配置注册为 istore；两者都是真实有效的安装位置。
    if [[ -f "$FEED_DIR/$pkg/Makefile" ]]; then
      path="$FEED_DIR/$pkg"
    elif [[ -f "$ISTORE_FEED_DIR/$pkg/Makefile" ]]; then
      path="$ISTORE_FEED_DIR/$pkg"
    fi
  fi
  if [[ ! -e "$path" || ! -f "$path/Makefile" ]]; then
    echo "MISSING_SOURCE: $pkg (checked=$FEED_DIR/$pkg,$ISTORE_FEED_DIR/$pkg)"
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
assert_unified_source() {
  local pkg="$1" expected="$2" actual feed
  for feed in "$FEED_DIR" "$ISTORE_FEED_DIR"; do
    if [[ -f "$feed/$pkg/Makefile" ]]; then
      actual="$(readlink -f "$feed/$pkg" 2>/dev/null || true)"
      if [[ "$actual" == "$expected" ]]; then
        echo "FOUND_SOURCE_PROVENANCE: $pkg (feed=$(basename "$feed"), source=$actual)"
        return 0
      fi
    fi
  done
  echo "MISSING_SOURCE_PROVENANCE: $pkg (expected $expected, got ${actual:-<none>})"
  missing=1
}
assert_unified_source luci-app-store "$KENZO_SOURCE/luci-app-store"
assert_unified_source luci-lib-taskd "$KENZO_SOURCE/luci-lib-taskd"
assert_unified_source luci-lib-xterm "$KENZO_SOURCE/luci-lib-xterm"
assert_unified_source taskd "$KENZO_SOURCE/taskd"
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
