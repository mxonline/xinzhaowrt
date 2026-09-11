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
commit='27e26e324bee0b0c2a4eb58e2e9121fea5d43194'
build_id='static-test'
mkdir -p "$ROOTFS/etc" "$ROOTFS/www/luci-static/xinzhao"
"$PROJECT_ROOT/scripts/resolve-build-identity.sh" "$PROJECT_ROOT/VERSION" "$commit" "$build_id" "$ROOTFS"
cp "$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults" "$ROOTFS/etc/uci-defaults/99-xinzhao-defaults"

bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$CONFIG" "$ROOTFS" "$commit" "$build_id"

echo 'PASS: final rootfs identity verifier accepts an embedded project release and defaults overlay.'
