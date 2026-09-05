#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

CONFIG="$TEST_ROOT/.config"
cat > "$CONFIG" <<'CONFIG'
CONFIG_TARGET_qualcommax=y
CONFIG_VERSION_NUMBER="0.1.0"
CONFIG

bash "$PROJECT_ROOT/scripts/apply-version-identity.sh" "$CONFIG"

VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
grep -qxF 'CONFIG_IMAGEOPT=y' "$CONFIG"
grep -qxF 'CONFIG_VERSIONOPT=y' "$CONFIG"
grep -qxF 'CONFIG_VERSION_DIST="XinZhaoWrt"' "$CONFIG"
grep -qxF "CONFIG_VERSION_NUMBER=\"$VERSION\"" "$CONFIG"
grep -qxF 'CONFIG_VERSION_MANUFACTURER="XinZhao Network"' "$CONFIG"
grep -qxF 'CONFIG_VERSION_PRODUCT="JDCloud Arthur RE-SS-01"' "$CONFIG"

echo 'PASS: build config identity is injected from VERSION.'
