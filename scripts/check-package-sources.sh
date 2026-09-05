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

# Verify each package against the same pinned source exposed by add-custom-packages.sh.
KENZO_SOURCE="$SRC/.xinzhao-sources/kenzok8-openwrt-packages"
ISTORE_SOURCE="$SRC/.xinzhao-sources/istore"
ISTOREOS_LUCI_SOURCE="$SRC/.xinzhao-sources/istoreos-luci"
ADGUARD_MATURE_SOURCE="$SRC/.xinzhao-sources/kenzok8-adguardhome"
IMMORTAL_LUCI_SOURCE="$SRC/.xinzhao-sources/immortalwrt-luci"
assert_source luci-app-quickstart "$ISTOREOS_LUCI_SOURCE/luci/luci-app-quickstart"
assert_source luci-app-adguardhome "$ADGUARD_MATURE_SOURCE/luci-app-adguardhome"
assert_source luci-app-istorex "$KENZO_SOURCE/luci-app-istorex"
assert_istore_source() {
  local pkg="$1" expected="$2" actual
  actual="$(readlink -f "$ISTORE_FEED_DIR/$pkg" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "MISSING_SOURCE_PROVENANCE: $pkg (expected $expected, got ${actual:-<none>})"
    missing=1
  else
    echo "FOUND_SOURCE_PROVENANCE: $pkg (feed=istore, source=$actual)"
  fi
}
assert_istore_source luci-app-store "$ISTORE_SOURCE/luci/luci-app-store"
assert_istore_source luci-lib-taskd "$ISTORE_SOURCE/luci/luci-lib-taskd"
assert_istore_source luci-lib-xterm "$ISTORE_SOURCE/luci/luci-lib-xterm"
assert_istore_source taskd "$ISTORE_SOURCE/luci/taskd"

if [[ -e "$SRC/.xinzhao-feed/luci-app-store" || -e "$FEED_DIR/luci-app-store" ]]; then
  echo "DUPLICATE_SOURCE: luci-app-store must not exist in .xinzhao-feed; use feed=istore"
  missing=1
fi
for pkg in luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol; do
  assert_source "$pkg" "$IMMORTAL_LUCI_SOURCE/applications/$pkg"
done
for pkg in luci-app-autoreboot luci-app-firewall luci-app-package-manager luci-app-pbr luci-app-samba4; do
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
