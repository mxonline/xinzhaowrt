#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
CONFIG="$TEST_ROOT/full.config"
ROOTFS="$TEST_ROOT/rootfs"
mkdir -p "$ROOTFS/etc/uci-defaults"
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

bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS"

echo 'PASS: final rootfs identity verifier accepts an embedded project release and defaults overlay.'
