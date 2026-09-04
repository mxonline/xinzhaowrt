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
printf '%s\n' '{"admin/services/adguardhome":{"title":"AdGuard Home"}}' > "$ROOTFS/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' '{"luci-app-adguardhome":{"read":{"ubus":{"service":["list"]}}}}' > "$ROOTFS/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
printf '%s\n' "'use strict'; 'require form'; form.Map('adguardhome'); form.TypedSection; object: 'service'; method: 'list'; poll.add;" > "$ROOTFS/www/luci-static/resources/view/adguardhome/config.js"
printf '%s\n' "config adguardhome 'config'" > "$ROOTFS/etc/config/adguardhome"
printf '%s\n' '#!/bin/sh /etc/rc.common' > "$ROOTFS/etc/init.d/adguardhome"
printf '%s\n' 'zh-cn locale' > "$ROOTFS/www/luci-static/resources/i18n/base.zh-cn.lmo"
printf '%s\n' 'argon' > "$ROOTFS/www/luci-static/argon/marker"
printf '%s\n' 'kucat' > "$ROOTFS/www/luci-static/kucat/marker"
printf '%s\n' 'quickstart' > "$ROOTFS/www/luci-static/quickstart/index.js"

bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS"

# Fail closed if a legacy uppercase AdGuard manager survives final assembly.
mkdir -p "$ROOTFS/usr/lib/lua/luci/controller"
printf '%s\n' 'legacy' > "$ROOTFS/usr/lib/lua/luci/controller/AdGuardHome.lua"
if bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" >/dev/null 2>&1; then
  echo 'FAIL: final rootfs verifier accepted legacy uppercase AdGuard manager.' >&2
  exit 1
fi
rm -f "$ROOTFS/usr/lib/lua/luci/controller/AdGuardHome.lua"

# Fail closed if preserved-upgrade Chinese convergence is absent.
rm -f "$ROOTFS/etc/hotplug.d/iface/95-xinzhao-luci-converge"
if bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" >/dev/null 2>&1; then
  echo 'FAIL: final rootfs verifier accepted missing preserved-upgrade LuCI convergence trigger.' >&2
  exit 1
fi

echo 'PASS: final rootfs identity verifier enforces mature AdGuard, zh_cn, themes, QuickStart, and preserved-upgrade convergence.'
