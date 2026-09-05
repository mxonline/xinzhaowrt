#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the real upstream Kconfig normalizer. This test is run with an
# ImmortalWrt source tree and must finish before any download or compile step.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: $0 <immortalwrt-source-dir>}"
CONFIG="$SRC/.config"
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"

[[ -f "$SRC/Makefile" ]] || { echo "ERROR: missing OpenWrt Makefile: $SRC" >&2; exit 1; }
[[ -n "$VERSION" ]] || { echo 'ERROR: VERSION is empty' >&2; exit 1; }

cp "$PROJECT_ROOT/config/arthur.config" "$CONFIG"
if ! grep -qx 'CONFIG_PACKAGE_xz-utils=y' "$CONFIG"; then
  printf '\nCONFIG_PACKAGE_xz-utils=y\n' >> "$CONFIG"
fi

bash "$PROJECT_ROOT/scripts/apply-version-identity.sh" "$CONFIG"
make -C "$SRC" defconfig

require_config() {
  grep -qxF "$1" "$CONFIG" || { echo "ERROR: defconfig removed required identity setting: $1" >&2; exit 1; }
}

require_config 'CONFIG_IMAGEOPT=y'
require_config 'CONFIG_VERSIONOPT=y'
require_config 'CONFIG_VERSION_DIST="XinZhaoWrt"'
require_config "CONFIG_VERSION_NUMBER=\"$VERSION\""
require_config 'CONFIG_VERSION_MANUFACTURER="XinZhao Network"'
require_config 'CONFIG_VERSION_PRODUCT="JDCloud Arthur RE-SS-01"'

bash "$PROJECT_ROOT/scripts/check-config.sh" "$CONFIG"
echo 'PASS: Arthur version identity survives real make defconfig normalization.'
