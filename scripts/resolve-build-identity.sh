#!/usr/bin/env bash
set -Eeuo pipefail

VERSION_FILE="${1:?usage: $0 <version-file> <full-commit> <build-id> <overlay-root>}"
FULL_COMMIT="${2:?usage: $0 <version-file> <full-commit> <build-id> <overlay-root>}"
BUILD_ID="${3:?usage: $0 <version-file> <full-commit> <build-id> <overlay-root>}"
DEST="${4:?usage: $0 <version-file> <full-commit> <build-id> <overlay-root>}"

VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid firmware version: $VERSION" >&2; exit 1; }
[[ "$FULL_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "ERROR: full source commit is required" >&2; exit 1; }
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid build ID" >&2; exit 1; }

SHORT_COMMIT="${FULL_COMMIT:0:9}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%F)}"
mkdir -p "$DEST/etc" "$DEST/www/luci-static/xinzhao"

cat > "$DEST/etc/xinzhao-build-info" <<INFO
Firmware: XinZhaoWrt
Version: $VERSION
Builder: 新肇数码
Build Date: $BUILD_DATE
Git Commit: $SHORT_COMMIT
Build ID: $BUILD_ID
Target: qualcommax/ipq60xx
Profile: jdcloud_re-ss-01
INFO

cat > "$DEST/www/luci-static/xinzhao/build-info.json" <<JSON
{
  "Firmware": "XinZhaoWrt",
  "Version": "$VERSION",
  "Builder": "新肇数码",
  "Build Date": "$BUILD_DATE",
  "Git Commit": "$SHORT_COMMIT",
  "Build ID": "$BUILD_ID",
  "Target": "qualcommax/ipq60xx",
  "Profile": "jdcloud_re-ss-01"
}
JSON

cat > "$DEST/etc/openwrt_release" <<RELEASE
DISTRIB_ID='XinZhaoWrt'
DISTRIB_RELEASE='$VERSION'
DISTRIB_REVISION='r0+1-$SHORT_COMMIT'
DISTRIB_TARGET='qualcommax/ipq60xx'
DISTRIB_ARCH='aarch64_cortex-a53'
DISTRIB_DESCRIPTION='XinZhaoWrt $VERSION r0+1-$SHORT_COMMIT'
DISTRIB_TAINTS='no-all'
RELEASE

cat > "$DEST/etc/os-release" <<RELEASE
NAME='XinZhaoWrt'
VERSION='$VERSION'
VERSION_ID='$VERSION'
BUILD_ID='$BUILD_ID'
PRETTY_NAME='XinZhaoWrt $VERSION r0+1-$SHORT_COMMIT'
RELEASE

echo "BUILD_IDENTITY_MATERIALIZED=PASS version=$VERSION commit=$SHORT_COMMIT build_id=$BUILD_ID"
