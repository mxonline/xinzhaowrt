#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
CONFIG="$TEST_ROOT/full.config"
ROOTFS="$TEST_ROOT/rootfs"
mkdir -p "$ROOTFS/etc/uci-defaults" "$ROOTFS/www/luci-static/xinzhao"
cat > "$CONFIG" <<CONFIG
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="XinZhaoWrt"
CONFIG_VERSION_NUMBER="$VERSION"
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
cat > "$ROOTFS/www/luci-static/xinzhao/build-info.json" <<JSON
{
  "Firmware": "XinZhaoWrt",
  "Version": "$VERSION",
  "Builder": "新肇数码",
  "Build Date": "20260911",
  "Git Commit": "0123456789abcdef0123456789abcdef01234567",
  "Build ID": "test-build",
  "Target": "qualcommax/ipq60xx",
  "Profile": "jdcloud_re-ss-01"
}
JSON

bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS"

echo 'PASS: final rootfs identity verifier accepts an embedded project release, current web build-info, and defaults overlay.'
