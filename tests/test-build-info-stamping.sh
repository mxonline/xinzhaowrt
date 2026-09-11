#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOTFS="$TEST_ROOT/rootfs"
mkdir -p "$ROOTFS/www/luci-static/xinzhao"
cp "$PROJECT_ROOT/files/www/luci-static/xinzhao/build-info.json" "$ROOTFS/www/luci-static/xinzhao/build-info.json"

VERSION='0.1.4-test'
BUILD_DATE='20260911'
SOURCE_SHA='0123456789abcdef0123456789abcdef01234567'
BUILD_ID='34601962231'

bash "$PROJECT_ROOT/scripts/stamp-build-info.sh" \
  "$ROOTFS" "$VERSION" "$BUILD_DATE" "$SOURCE_SHA" "$BUILD_ID"

python3 - "$ROOTFS/www/luci-static/xinzhao/build-info.json" "$VERSION" "$BUILD_DATE" "$SOURCE_SHA" "$BUILD_ID" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
version, build_date, source_sha, build_id = sys.argv[2:]
data = json.loads(path.read_text(encoding="utf-8"))
expected = {
    "Firmware": "XinZhaoWrt",
    "Version": version,
    "Build Date": build_date,
    "Git Commit": source_sha,
    "Build ID": build_id,
    "Target": "qualcommax/ipq60xx",
    "Profile": "jdcloud_re-ss-01",
}
for key, value in expected.items():
    actual = data.get(key)
    if actual != value:
        raise SystemExit(f"FAIL: build-info {key!r}={actual!r}, expected {value!r}")
for value in data.values():
    if isinstance(value, str) and value.startswith("@") and value.endswith("@"):
        raise SystemExit(f"FAIL: unresolved build-info placeholder: {value}")
print("PASS: web build-info template is stamped with current build identity.")
PY
