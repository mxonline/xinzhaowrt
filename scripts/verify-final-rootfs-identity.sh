#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:?usage: $0 <full.config> <final-rootfs-dir> [full-commit] [build-id]}"
ROOTFS_DIR="${2:?usage: $0 <full.config> <final-rootfs-dir> [full-commit] [build-id]}"
EXPECTED_COMMIT="${3:-27e26e324}"
EXPECTED_BUILD_ID="${4:-test-build}"
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"

[[ -n "$VERSION" ]] || { echo 'ERROR: VERSION is empty' >&2; exit 1; }
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-fA-F]{9,40}$ ]] || { echo "ERROR: invalid expected commit: $EXPECTED_COMMIT" >&2; exit 1; }
[[ "$EXPECTED_BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid expected build ID: $EXPECTED_BUILD_ID" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: missing full config: $CONFIG_FILE" >&2; exit 1; }
[[ -d "$ROOTFS_DIR" ]] || { echo "ERROR: missing final rootfs directory: $ROOTFS_DIR" >&2; exit 1; }

require_config() {
  grep -qxF "$1" "$CONFIG_FILE" || { echo "ERROR: missing $1 in $CONFIG_FILE" >&2; exit 1; }
}

require_config 'CONFIG_VERSIONOPT=y'
require_config 'CONFIG_VERSION_DIST="XinZhaoWrt"'
require_config "CONFIG_VERSION_NUMBER=\"$VERSION\""
[[ -f "$ROOTFS_DIR/etc/uci-defaults/99-xinzhao-defaults" ]] || {
  echo 'ERROR: final rootfs is missing /etc/uci-defaults/99-xinzhao-defaults' >&2
  exit 1
}

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python
"$PYTHON_BIN" - "$ROOTFS_DIR" "$VERSION" "$EXPECTED_COMMIT" "$EXPECTED_BUILD_ID" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
version = sys.argv[2]
full_commit = sys.argv[3].lower()
build_id = sys.argv[4]
short_commit = full_commit[:9]

def fail(message):
    raise SystemExit(f"ERROR: {message}")

def read(path):
    if not path.is_file():
        fail(f"final rootfs is missing {path}")
    return path.read_text(encoding="utf-8", errors="strict")

def parse_shell_assignments(path):
    result = {}
    for line in read(path).splitlines():
        match = re.fullmatch(r"([A-Z0-9_]+)='([^']*)'", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result

info_path = root / "etc" / "xinzhao-build-info"
info_text = read(info_path)
info_expected = {
    "Firmware": "XinZhaoWrt",
    "Version": version,
    "Git Commit": short_commit,
    "Build ID": build_id,
    "Target": "qualcommax/ipq60xx",
    "Profile": "jdcloud_re-ss-01",
}
for key, value in info_expected.items():
    if f"{key}: {value}" not in info_text.splitlines():
        fail(f"{info_path} has no exact {key}={value}")
if "@VERSION@" in info_text or "@BUILD_ID@" in info_text:
    fail(f"{info_path} still contains a build placeholder")

json_path = root / "www" / "luci-static" / "xinzhao" / "build-info.json"
try:
    build_json = json.loads(read(json_path))
except json.JSONDecodeError as exc:
    fail(f"{json_path} is not valid JSON: {exc}")
json_expected = {
    "Firmware": "XinZhaoWrt",
    "Version": version,
    "Git Commit": short_commit,
    "Build ID": build_id,
    "Target": "qualcommax/ipq60xx",
    "Profile": "jdcloud_re-ss-01",
}
for key, value in json_expected.items():
    if build_json.get(key) != value:
        fail(f"{json_path} has no exact {key}={value}: {build_json!r}")
if "@VERSION@" in json_path.read_text(encoding="utf-8") or "@BUILD_ID@" in json_path.read_text(encoding="utf-8"):
    fail(f"{json_path} still contains a build placeholder")

release = parse_shell_assignments(root / "etc" / "openwrt_release")
release_expected = {
    "DISTRIB_ID": "XinZhaoWrt",
    "DISTRIB_RELEASE": version,
    "DISTRIB_REVISION": f"r0+1-{short_commit}",
    "DISTRIB_TARGET": "qualcommax/ipq60xx",
    "DISTRIB_ARCH": "aarch64_cortex-a53",
}
if any(release.get(key) != value for key, value in release_expected.items()):
    fail(f"/etc/openwrt_release identity mismatch: {release!r}")

os_release = parse_shell_assignments(root / "etc" / "os-release")
os_expected = {
    "NAME": "XinZhaoWrt",
    "VERSION": version,
    "VERSION_ID": version,
    "BUILD_ID": build_id,
}
if any(os_release.get(key) != value for key, value in os_expected.items()):
    fail(f"/etc/os-release identity mismatch: {os_release!r}")

print(f"IDENTITY_MATCH=PASS version={version} commit={short_commit} build_id={build_id}")
PY

echo "PASS: final rootfs contains XinZhaoWrt v$VERSION identity and first-boot defaults overlay."
