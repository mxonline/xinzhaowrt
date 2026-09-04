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

require_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "ERROR: final rootfs is missing $file" >&2; exit 1; }
}

require_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "ERROR: final rootfs is missing directory $dir" >&2; exit 1; }
}

require_file_text() {
  local file="$1"
  local expected="$2"
  require_file "$file"
  grep -Fq "$expected" "$file" || { echo "ERROR: $file does not contain $expected" >&2; exit 1; }
}

reject_path() {
  local path="$1"
  [[ ! -e "$path" ]] || { echo "ERROR: obsolete production path survived final rootfs assembly: $path" >&2; exit 1; }
}

require_config 'CONFIG_VERSIONOPT=y'
require_config 'CONFIG_VERSION_DIST="XinZhaoWrt"'
require_config "CONFIG_VERSION_NUMBER=\"$VERSION\""
require_config 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y'
require_config 'CONFIG_PACKAGE_luci-theme-argon=y'
require_config 'CONFIG_PACKAGE_luci-theme-kucat=y'
require_config 'CONFIG_PACKAGE_luci-app-adguardhome=y'
require_config 'CONFIG_PACKAGE_luci-app-quickstart=y'

require_file_text "$ROOTFS_DIR/etc/openwrt_release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/openwrt_release" "$VERSION"
require_file_text "$ROOTFS_DIR/etc/os-release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/os-release" "$VERSION"
require_file "$ROOTFS_DIR/etc/uci-defaults/99-xinzhao-defaults"

# Preserved-config sysupgrade convergence.  These rootfs files must survive even
# when an older /etc/config/luci and old uci-default deletion state are kept.
require_file "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.lang='zh_cn'"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.mediaurlbase='/luci-static/argon'"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" "luci.main.homepage='admin/quickstart'"
require_file_text "$ROOTFS_DIR/usr/libexec/xinzhao/luci-upgrade-converge.sh" 'luci-migration-commit'
require_file "$ROOTFS_DIR/etc/hotplug.d/iface/95-xinzhao-luci-converge"
require_file_text "$ROOTFS_DIR/etc/hotplug.d/iface/95-xinzhao-luci-converge" '/usr/libexec/xinzhao/luci-upgrade-converge.sh'

# Locale package bytes must actually be present, not merely selected in Kconfig.
if ! find "$ROOTFS_DIR" -type f \( -iname '*zh-cn*.lmo' -o -iname '*zh_cn*.lmo' \) -print -quit | grep -q .; then
  echo 'ERROR: final rootfs has no Simplified Chinese LuCI locale .lmo payload.' >&2
  exit 1
fi
require_dir "$ROOTFS_DIR/www/luci-static/argon"
require_dir "$ROOTFS_DIR/www/luci-static/kucat"
require_file "$ROOTFS_DIR/www/luci-static/quickstart/index.js"

# Mature AdGuard Home manager must be the only manager implementation in the
# production rootfs.  Lowercase package paths are authoritative.
require_file "$ROOTFS_DIR/usr/share/luci/menu.d/luci-app-adguardhome.json"
require_file "$ROOTFS_DIR/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
require_file "$ROOTFS_DIR/www/luci-static/resources/view/adguardhome/config.js"
require_file "$ROOTFS_DIR/etc/config/adguardhome"
require_file "$ROOTFS_DIR/etc/init.d/adguardhome"
require_file_text "$ROOTFS_DIR/www/luci-static/resources/view/adguardhome/config.js" "form.Map('adguardhome'"
require_file_text "$ROOTFS_DIR/www/luci-static/resources/view/adguardhome/config.js" 'form.TypedSection'
require_file_text "$ROOTFS_DIR/www/luci-static/resources/view/adguardhome/config.js" "object: 'service'"
require_file_text "$ROOTFS_DIR/www/luci-static/resources/view/adguardhome/config.js" "method: 'list'"
require_file_text "$ROOTFS_DIR/usr/share/rpcd/acl.d/luci-app-adguardhome.json" 'service'
require_file_text "$ROOTFS_DIR/usr/share/rpcd/acl.d/luci-app-adguardhome.json" 'adguardhome'

for obsolete in \
  "$ROOTFS_DIR/usr/lib/lua/luci/controller/AdGuardHome.lua" \
  "$ROOTFS_DIR/usr/lib/lua/luci/model/cbi/AdGuardHome" \
  "$ROOTFS_DIR/usr/lib/lua/luci/view/AdGuardHome" \
  "$ROOTFS_DIR/etc/config/AdGuardHome" \
  "$ROOTFS_DIR/etc/init.d/AdGuardHome" \
  "$ROOTFS_DIR/www/luci-static/resources/view/luci-app-adguardhome/index.js"; do
  reject_path "$obsolete"
done

if grep -Fq 'admin/services/AdGuardHome' "$ROOTFS_DIR/usr/share/luci/menu.d/luci-app-adguardhome.json"; then
  echo 'ERROR: final AdGuard menu still registers the obsolete uppercase service namespace.' >&2
  exit 1
fi

echo "PASS: final rootfs contains XinZhaoWrt v$VERSION identity, mature AdGuard manager, zh_cn locale, themes, QuickStart, and preserved-upgrade LuCI convergence."
