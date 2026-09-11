#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
CONFIG="$TEST_ROOT/full.config"
ROOTFS="$TEST_ROOT/rootfs"
OUTPUT="$TEST_ROOT/verifier.out"
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
  "Version": "0.0.0-stale",
  "Builder": "新肇数码",
  "Build Date": "19700101",
  "Git Commit": "deadbeef",
  "Build ID": "stale-build",
  "Target": "qualcommax/ipq60xx",
  "Profile": "jdcloud_re-ss-01"
}
JSON

if bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" >"$OUTPUT" 2>&1; then
  cat "$OUTPUT" >&2
  echo "FAIL: final rootfs identity verifier accepted stale web build-info version; expected $VERSION." >&2
  exit 1
fi

echo 'PASS: final rootfs identity verifier rejects stale web build-info version.'
