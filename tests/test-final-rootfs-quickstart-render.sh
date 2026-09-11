#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:?usage: $0 <full.config> <final-rootfs> [expected-error]}"
rootfs="${2:?usage: $0 <full.config> <final-rootfs> [expected-error]}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python
"$PYTHON_BIN" "$root/scripts/luci-legacy-template-smoke.py" \
  --source-root "$root/work/immortalwrt" \
  --rootfs "$rootfs" \
  --config "$config"

echo 'FINAL_ROOTFS_QUICKSTART_RENDER=PASS'
