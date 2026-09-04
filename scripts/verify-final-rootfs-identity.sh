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

require_config 'CONFIG_VERSIONOPT=y'
require_config 'CONFIG_VERSION_DIST="XinZhaoWrt"'
require_config "CONFIG_VERSION_NUMBER=\"$VERSION\""
require_config 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y'
require_config 'CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y'
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

echo "PASS: final rootfs contains XinZhaoWrt v$VERSION identity, first-boot defaults, and required LuCI Chinese translations."
