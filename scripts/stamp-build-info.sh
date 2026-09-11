#!/usr/bin/env bash
set -Eeuo pipefail

ROOTFS_DIR="${1:?usage: $0 <rootfs-dir> <version> <build-date> <source-sha> <build-id>}"
VERSION="${2:?missing version}"
BUILD_DATE="${3:?missing build date}"
SOURCE_SHA="${4:?missing source sha}"
BUILD_ID="${5:?missing build id}"
BUILD_INFO="$ROOTFS_DIR/www/luci-static/xinzhao/build-info.json"

[[ -d "$ROOTFS_DIR" ]] || { echo "ERROR: rootfs directory does not exist: $ROOTFS_DIR" >&2; exit 1; }
[[ -f "$BUILD_INFO" ]] || { echo "ERROR: web build-info template is missing: $BUILD_INFO" >&2; exit 1; }

python3 - "$BUILD_INFO" "$VERSION" "$BUILD_DATE" "$SOURCE_SHA" "$BUILD_ID" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
version, build_date, source_sha, build_id = sys.argv[2:]

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"ERROR: cannot parse web build-info template {path}: {exc}")

data.update({
    "Firmware": "XinZhaoWrt",
    "Version": version,
    "Builder": "新肇数码",
    "Build Date": build_date,
    "Git Commit": source_sha,
    "Build ID": build_id,
    "Target": "qualcommax/ipq60xx",
    "Profile": "jdcloud_re-ss-01",
})

for key, value in data.items():
    if isinstance(value, str) and value.startswith("@") and value.endswith("@"):
        raise SystemExit(f"ERROR: unresolved web build-info placeholder {key}={value}")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "PASS: stamped web build-info version=$VERSION date=$BUILD_DATE source=$SOURCE_SHA build_id=$BUILD_ID"
