#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
FEED_DIR="$SRC/package/feeds/xinzhao"
ISTORE_FEED_DIR="$SRC/package/feeds/istore"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/config/istore-quickstart.lock"

OPENCLASH_SELECTED_MAKEFILE="$SRC/package/feeds/xinzhao/openclash-core/Makefile" \
  bash "$PROJECT_ROOT/scripts/check-openclash-core-authority.sh" \
  "$SRC" "$PROJECT_ROOT/package/xinzhao/openclash-core"

required=(
  luci-app-istorex
  luci-app-lucky
  luci-app-quickfile
  luci-app-quickstart
  luci-app-linkease
  luci-lib-linkeasefile
  linkease
  linkease-common-bin
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

# Verify iStoreX uses Kenzok8, QuickStart uses the official iStoreOS LinkEase
# repositories, and store uses official linkease/istore.
KENZO_SOURCE="$SRC/.xinzhao-sources/kenzok8-openwrt-packages"
ISTORE_SOURCE="$SRC/.xinzhao-sources/istore"
ISTOREOS_LUCI_SOURCE="$SRC/.xinzhao-sources/istoreos-luci"
ISTOREOS_PACKAGES_SOURCE="$SRC/.xinzhao-sources/istoreos-packages"
IMMORTAL_LUCI_SOURCE="$SRC/.xinzhao-sources/immortalwrt-luci"
assert_source luci-app-quickstart "$ISTOREOS_LUCI_SOURCE/luci/luci-app-quickstart"
assert_source quickstart "$ISTOREOS_PACKAGES_SOURCE/network/services/quickstart"
assert_source luci-app-linkease "$ISTOREOS_LUCI_SOURCE/luci/luci-app-linkease"
assert_source luci-lib-linkeasefile "$ISTOREOS_LUCI_SOURCE/luci/luci-lib-linkeasefile"
assert_source linkease "$ISTOREOS_PACKAGES_SOURCE/network/services/linkease"
assert_source linkease-common-bin "$ISTOREOS_PACKAGES_SOURCE/network/services/linkease-common-bin"
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

assert_locked_ref() {
  local name="$1" source_dir="$2" expected="$3" actual
  actual="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "SOURCE_REF_MISMATCH: $name (expected=$expected actual=$actual)"
    missing=1
  fi
}
assert_source_text() {
  local file="$1" expected="$2" label="$3"
  if ! grep -Fq -- "$expected" "$file"; then
    echo "SOURCE_CONTENT_MISMATCH: $label (expected=$expected file=$file)"
    missing=1
  fi
}
assert_locked_ref nas-packages "$ISTOREOS_PACKAGES_SOURCE" "$ISTORE_QUICKSTART_REF"
assert_locked_ref nas-packages-luci "$ISTOREOS_LUCI_SOURCE" "$ISTORE_QUICKSTART_LUCI_REF"
LINKEASE_SOURCE="$ISTOREOS_PACKAGES_SOURCE/network/services/linkease"
LINKEASE_COMMON_SOURCE="$ISTOREOS_PACKAGES_SOURCE/network/services/linkease-common-bin"
LINKEASE_APP_SOURCE="$ISTOREOS_LUCI_SOURCE/luci/luci-app-linkease"
LINKEASE_FILE_LIB_SOURCE="$ISTOREOS_LUCI_SOURCE/luci/luci-lib-linkeasefile"
assert_source_text "$LINKEASE_SOURCE/Makefile" "PKG_SOURCE_DATE:=$ISTORE_LINKEASE_VERSION" 'LinkEase runtime version'
assert_source_text "$LINKEASE_SOURCE/Makefile" "PKG_RELEASE:=$ISTORE_LINKEASE_RELEASE" 'LinkEase package release'
assert_source_text "$LINKEASE_SOURCE/Makefile" "PKG_HASH:=$ISTORE_LINKEASE_AARCH64_BIN_SHA256" 'LinkEase AArch64 runtime hash'
assert_source_text "$LINKEASE_COMMON_SOURCE/Makefile" "PKG_SOURCE_DATE:=$ISTORE_LINKEASE_COMMON_BIN_VERSION" 'LinkEase common runtime version'
assert_source_text "$LINKEASE_COMMON_SOURCE/Makefile" "PKG_RELEASE:=$ISTORE_LINKEASE_COMMON_BIN_RELEASE" 'LinkEase common package release'
assert_source_text "$LINKEASE_COMMON_SOURCE/Makefile" "PKG_HASH:=$ISTORE_LINKEASE_COMMON_AARCH64_BIN_SHA256" 'LinkEase common AArch64 runtime hash'
assert_source_text "$LINKEASE_APP_SOURCE/Makefile" "PKG_VERSION:=$ISTORE_LINKEASE_LUCI_VERSION-r$ISTORE_LINKEASE_LUCI_RELEASE" 'LinkEase LuCI app version'
assert_source_text "$LINKEASE_FILE_LIB_SOURCE/Makefile" "PKG_VERSION:=$ISTORE_LINKEASE_LUCI_VERSION-r$ISTORE_LINKEASE_LUCI_RELEASE" 'LinkEase file library version'
assert_source_text "$LINKEASE_APP_SOURCE/Makefile" 'LUCI_DEPENDS:=+linkease +luci-lib-linkeasefile' 'QuickStart LinkEase app runtime dependencies'
assert_source_text "$LINKEASE_FILE_LIB_SOURCE/Makefile" 'LUCI_DEPENDS:=+linkease-common-bin' 'LinkEase common runtime dependency'
assert_source_text "$LINKEASE_SOURCE/files/linkease.uci-default" 'set_default allowPublic 0' 'LinkEase safe public-access default'
if grep -Fq '$(1)/etc/uci-defaults/linkease-fw' "$LINKEASE_COMMON_SOURCE/Makefile"; then
  echo 'UNSAFE_SOURCE_PAYLOAD: linkease-common-bin still installs the WAN 8897 UCI-default'
  missing=1
fi

if [[ -e "$SRC/.xinzhao-feed/luci-app-store" || -e "$FEED_DIR/luci-app-store" ]]; then
  echo "DUPLICATE_SOURCE: luci-app-store must not exist in .xinzhao-feed; use feed=istore"
  missing=1
fi
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
