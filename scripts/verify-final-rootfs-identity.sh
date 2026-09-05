#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:?usage: $0 <full.config> <final-rootfs-dir>}"
ROOTFS_DIR="${2:?usage: $0 <full.config> <final-rootfs-dir>}"
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"

[[ -n "$VERSION" ]] || { echo 'ERROR: VERSION is empty' >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: missing full config: $CONFIG_FILE" >&2; exit 1; }
[[ -d "$ROOTFS_DIR" ]] || { echo "ERROR: missing final rootfs directory: $ROOTFS_DIR" >&2; exit 1; }

require_config() {
  grep -qxF "$1" "$CONFIG_FILE" || { echo "ERROR: missing $1 in $CONFIG_FILE" >&2; exit 1; }
}

require_file_text() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || { echo "ERROR: final rootfs is missing $file" >&2; exit 1; }
  grep -Fq "$expected" "$file" || { echo "ERROR: $file does not contain $expected" >&2; exit 1; }
}

require_file() {
  [[ -f "$1" ]] || { echo "ERROR: final rootfs is missing $1" >&2; exit 1; }
}

require_dir() {
  [[ -d "$1" ]] || { echo "ERROR: final rootfs is missing directory $1" >&2; exit 1; }
}

require_config 'CONFIG_VERSIONOPT=y'
require_config 'CONFIG_VERSION_DIST="XinZhaoWrt"'
require_config "CONFIG_VERSION_NUMBER=\"$VERSION\""
require_config 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y'
require_config 'CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y'
require_config 'CONFIG_PACKAGE_luci-theme-argon=y'
require_config 'CONFIG_PACKAGE_luci-theme-kucat=y'
require_config 'CONFIG_PACKAGE_luci-app-adguardhome=y'
require_config 'CONFIG_PACKAGE_luci-app-quickstart=y'
require_file_text "$ROOTFS_DIR/etc/openwrt_release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/openwrt_release" "$VERSION"
require_file_text "$ROOTFS_DIR/etc/os-release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/os-release" "$VERSION"
[[ -f "$ROOTFS_DIR/etc/uci-defaults/99-xinzhao-defaults" ]] || {
  echo 'ERROR: final rootfs is missing /etc/uci-defaults/99-xinzhao-defaults' >&2
  exit 1
}
[[ -f "$ROOTFS_DIR/usr/lib/lua/luci/i18n/base.zh-cn.lmo" ]] || {
  echo 'ERROR: final rootfs is missing the LuCI base Simplified Chinese translation' >&2
  exit 1
}
[[ -f "$ROOTFS_DIR/usr/lib/lua/luci/i18n/quickstart.zh-cn.lmo" ]] || {
  echo 'ERROR: final rootfs is missing the QuickStart Simplified Chinese translation' >&2
  exit 1
}

# Preserved-config sysupgrade convergence keeps the accepted router-admin
# locale, theme and homepage when /etc/config/luci survives an upgrade.
require_file "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.lang='zh_cn'"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.mediaurlbase='/luci-static/argon'"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.homepage='admin/quickstart'"
require_file "$ROOTFS_DIR/etc/hotplug.d/iface/95-xinzhao-luci-converge"
require_file_text "$ROOTFS_DIR/etc/hotplug.d/iface/95-xinzhao-luci-converge" '/usr/libexec/xinzhao/luci-upgrade-converge.sh'

require_dir "$ROOTFS_DIR/www/luci-static/argon"
require_dir "$ROOTFS_DIR/www/luci-static/kucat"
require_file "$ROOTFS_DIR/www/luci-static/quickstart/index.js"

# The accepted kenzok8 package provides the complete uppercase CBI manager.
# Require its controller, all routes/models, config, init, YAML and ACL rather
# than accepting a partial custom page or an unrelated lowercase manager.
require_file "$ROOTFS_DIR/usr/share/luci/menu.d/luci-app-adguardhome.json"
require_file "$ROOTFS_DIR/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
require_file "$ROOTFS_DIR/usr/lib/lua/luci/controller/AdGuardHome.lua"
for model in overview base tools log manual; do
  require_file "$ROOTFS_DIR/usr/lib/lua/luci/model/cbi/AdGuardHome/$model.lua"
done
require_file "$ROOTFS_DIR/etc/config/AdGuardHome"
require_file "$ROOTFS_DIR/etc/init.d/AdGuardHome"
require_file "$ROOTFS_DIR/etc/AdGuardHome.yaml"
require_file "$ROOTFS_DIR/usr/lib/lua/luci/i18n/adguardhome.zh-cn.lmo"
require_file_text "$ROOTFS_DIR/usr/share/luci/menu.d/luci-app-adguardhome.json" 'admin/services/AdGuardHome'
require_file_text "$ROOTFS_DIR/usr/share/rpcd/acl.d/luci-app-adguardhome.json" '"AdGuardHome"'

echo "PASS: final rootfs contains XinZhaoWrt v$VERSION identity, mature AdGuard CBI manager, required LuCI Chinese translations, QuickStart, themes, and preserved-upgrade LuCI convergence."
