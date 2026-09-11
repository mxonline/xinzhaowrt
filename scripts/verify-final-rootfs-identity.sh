#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:?usage: $0 <full.config> <final-rootfs-dir>}"
ROOTFS_DIR="${2:?usage: $0 <full.config> <final-rootfs-dir>}"
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
BUILD_INFO="$ROOTFS_DIR/www/luci-static/xinzhao/build-info.json"

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
require_file_text "$ROOTFS_DIR/etc/openwrt_release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/openwrt_release" "$VERSION"
require_file_text "$ROOTFS_DIR/etc/os-release" 'XinZhaoWrt'
require_file_text "$ROOTFS_DIR/etc/os-release" "$VERSION"
[[ -f "$ROOTFS_DIR/etc/uci-defaults/99-xinzhao-defaults" ]] || {
  echo 'ERROR: final rootfs is missing /etc/uci-defaults/99-xinzhao-defaults' >&2
  exit 1
}

[[ -f "$BUILD_INFO" ]] || { echo "ERROR: final rootfs is missing $BUILD_INFO" >&2; exit 1; }
python3 - "$BUILD_INFO" "$VERSION" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_version = sys.argv[2]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"ERROR: invalid web build-info JSON: {exc}")

expected = {
    "Firmware": "XinZhaoWrt",
    "Version": expected_version,
    "Target": "qualcommax/ipq60xx",
    "Profile": "jdcloud_re-ss-01",
}
for key, value in expected.items():
    actual = data.get(key)
    if actual != value:
        raise SystemExit(f"ERROR: web build-info {key} mismatch: expected {value!r}, got {actual!r}")

for key in ("Builder", "Build Date", "Git Commit", "Build ID"):
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"ERROR: web build-info {key} is empty or missing")
    if value.startswith("@") and value.endswith("@"):
        raise SystemExit(f"ERROR: unresolved web build-info placeholder: {key}={value}")
PY

echo "PASS: final rootfs contains XinZhaoWrt v$VERSION identity, current web build-info, and first-boot defaults overlay."
