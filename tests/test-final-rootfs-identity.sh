#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
CONFIG="$TEST_ROOT/full.config"
ROOTFS="$TEST_ROOT/rootfs"
mkdir -p \
  "$ROOTFS/etc/uci-defaults" \
  "$ROOTFS/etc/config" \
  "$ROOTFS/etc/init.d" \
  "$ROOTFS/etc/hotplug.d/iface" \
  "$ROOTFS/usr/libexec/xinzhao" \
  "$ROOTFS/usr/lib/lua/luci/controller" \
  "$ROOTFS/usr/lib/lua/luci/model/cbi/AdGuardHome" \
  "$ROOTFS/usr/lib/lua/luci/i18n" \
  "$ROOTFS/usr/share/luci/menu.d" \
  "$ROOTFS/usr/share/rpcd/acl.d" \
  "$ROOTFS/www/luci-static/resources/view/adguardhome" \
  "$ROOTFS/www/luci-static/resources/i18n" \
  "$ROOTFS/www/luci-static/argon" \
  "$ROOTFS/www/luci-static/kucat" \
  "$ROOTFS/www/luci-static/quickstart"

cat > "$CONFIG" <<CONFIG
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="XinZhaoWrt"
CONFIG_VERSION_NUMBER="$VERSION"
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-theme-kucat=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-quickstart=y
CONFIG
cat > "$ROOTFS/etc/openwrt_release" <<RELEASE
DISTRIB_ID='XinZhaoWrt'
DISTRIB_RELEASE='$VERSION'
RELEASE
cat > "$ROOTFS/etc/os-release" <<RELEASE
NAME='XinZhaoWrt'
VERSION='$VERSION'
RELEASE
cp "$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults" "$ROOTFS/etc/uci-defaults/99-xinzhao-defaults"
cp "$PROJECT_ROOT/files/usr/libexec/xinzhao/luci-upgrade-converge.sh" "$ROOTFS/usr/libexec/xinzhao/luci-upgrade-converge.sh"
cp "$PROJECT_ROOT/files/etc/hotplug.d/iface/95-xinzhao-luci-converge" "$ROOTFS/etc/hotplug.d/iface/95-xinzhao-luci-converge"
printf '%s\n' '{"admin/services/AdGuardHome":{"title":"AdGuard Home"}}' > "$ROOTFS/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' '{"luci-app-adguardhome":{"read":{"uci":["AdGuardHome"]},"write":{"uci":["AdGuardHome"]}}}' > "$ROOTFS/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
printf '%s\n' 'controller mature' > "$ROOTFS/usr/lib/lua/luci/controller/AdGuardHome.lua"
for model in overview base tools log manual; do printf '%s\n' "mature $model" > "$ROOTFS/usr/lib/lua/luci/model/cbi/AdGuardHome/$model.lua"; done
printf '%s\n' "config AdGuardHome 'AdGuardHome'" > "$ROOTFS/etc/config/AdGuardHome"
printf '%s\n' '#!/bin/sh /etc/rc.common' > "$ROOTFS/etc/init.d/AdGuardHome"
printf '%s\n' 'yaml mature' > "$ROOTFS/etc/AdGuardHome.yaml"
printf '%s\n' 'zh-cn locale' > "$ROOTFS/usr/lib/lua/luci/i18n/base.zh-cn.lmo"
printf '%s\n' 'quickstart zh-cn locale' > "$ROOTFS/usr/lib/lua/luci/i18n/quickstart.zh-cn.lmo"
printf '%s\n' 'adguard zh-cn locale' > "$ROOTFS/usr/lib/lua/luci/i18n/adguardhome.zh-cn.lmo"
printf '%s\n' 'argon' > "$ROOTFS/www/luci-static/argon/marker"
printf '%s\n' 'kucat' > "$ROOTFS/www/luci-static/kucat/marker"
printf '%s\n' 'quickstart' > "$ROOTFS/www/luci-static/quickstart/index.js"

bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS"

# Fail closed if the complete mature AdGuard CBI manager is truncated.
rm -f "$ROOTFS/usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua"
if bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" >/dev/null 2>&1; then
  echo 'FAIL: final rootfs verifier accepted a truncated mature AdGuard CBI manager.' >&2
  exit 1
fi
printf '%s\n' 'mature manual' > "$ROOTFS/usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua"

# Fail closed if preserved-upgrade Chinese convergence is absent.
rm -f "$ROOTFS/etc/hotplug.d/iface/95-xinzhao-luci-converge"
if bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" >/dev/null 2>&1; then
  echo 'FAIL: final rootfs verifier accepted missing preserved-upgrade LuCI convergence trigger.' >&2
  exit 1
fi

echo 'PASS: final rootfs identity verifier enforces mature AdGuard CBI, zh_cn, themes, QuickStart, and preserved-upgrade convergence.'
