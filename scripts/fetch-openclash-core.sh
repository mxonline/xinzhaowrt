#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
PACKAGE_FILES="$SRC/package/xinzhao/openclash-core/files"
mkdir -p "$PACKAGE_FILES" "$SRC/dl"

stage_core() {
  local core_type="$1" lock="$2" archive="$3" staged="$4" report="$5" url partial
  [[ -f "$lock" ]] || { echo "ERROR: OpenClash $core_type Core lock missing: $lock" >&2; return 1; }
  url="$(python3 - "$lock" "$core_type" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    lock = json.load(f)
kind = sys.argv[2]
ref = lock.get('source_ref', '')
path = lock.get('asset_path', '')
if lock.get('source_repository') != 'vernesong/OpenClash':
    raise SystemExit('ERROR: Core source must be the official OpenClash repository')
if not re.fullmatch(r'[0-9a-f]{40}', ref):
    raise SystemExit('ERROR: Core source ref must be a full immutable commit')
if lock.get('core_type') != kind or path != f'master/{kind.lower()}/clash-linux-arm64.tar.gz':
    raise SystemExit('ERROR: unexpected official OpenClash Core asset path/type')
print(f'https://raw.githubusercontent.com/vernesong/OpenClash/{ref}/{path}')
PY
  )"

  if [[ ! -s "$archive" ]] || ! python3 "$PROJECT_ROOT/scripts/stage-openclash-core.py" "$lock" "$archive" "$staged" "$report" >/dev/null 2>&1; then
    rm -f "$archive"
    partial="$archive.part.$$"
    trap 'rm -f "$partial"' RETURN
    curl --fail --location --silent --show-error --retry 3 --output "$partial" "$url"
    mv "$partial" "$archive"
  fi
  python3 "$PROJECT_ROOT/scripts/stage-openclash-core.py" "$lock" "$archive" "$staged" "$report"
}

stage_core Meta \
  "$PROJECT_ROOT/config/openclash-core.lock.json" \
  "$SRC/dl/openclash-core-meta-arm64.tar.gz" \
  "$PACKAGE_FILES/clash_meta" \
  "$PROJECT_ROOT/output/openclash-core-source-verification.txt"
stage_core Smart \
  "$PROJECT_ROOT/config/openclash-smart-core.lock.json" \
  "$SRC/dl/openclash-core-smart-arm64.tar.gz" \
  "$PACKAGE_FILES/clash_smart" \
  "$PROJECT_ROOT/output/openclash-smart-core-source-verification.txt"

echo 'OPENCLASH_META_CORE_FETCH=PASS'
echo 'OPENCLASH_SMART_CORE_FETCH=PASS'
