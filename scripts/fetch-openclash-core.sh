#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
LOCK="$PROJECT_ROOT/config/openclash-core.lock.json"
STAGED="$SRC/package/xinzhao/openclash-core/files/clash_meta"
ARCHIVE="$SRC/dl/openclash-core-meta-arm64.tar.gz"
REPORT="$PROJECT_ROOT/output/openclash-core-source-verification.txt"

[[ -f "$LOCK" ]] || { echo "ERROR: OpenClash Core lock missing: $LOCK" >&2; exit 1; }
mkdir -p "$(dirname "$STAGED")" "$(dirname "$ARCHIVE")"

URL="$(python3 - "$LOCK" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    lock = json.load(f)
if lock.get('source_repository') != 'vernesong/OpenClash':
    raise SystemExit('ERROR: Core source must be the official OpenClash repository')
ref = lock.get('source_ref', '')
path = lock.get('asset_path', '')
if not re.fullmatch(r'[0-9a-f]{40}', ref):
    raise SystemExit('ERROR: Core source ref must be a full immutable commit')
if path != 'master/meta/clash-linux-arm64.tar.gz':
    raise SystemExit('ERROR: unexpected official OpenClash Core asset path')
print(f'https://raw.githubusercontent.com/vernesong/OpenClash/{ref}/{path}')
PY
)"

if [[ -s "$ARCHIVE" ]] && \
   python3 "$PROJECT_ROOT/scripts/stage-openclash-core.py" "$LOCK" "$ARCHIVE" "$STAGED" "$REPORT" >/dev/null 2>&1; then
  echo 'OPENCLASH_CORE_FETCH=CACHE_HIT'
  exit 0
fi

rm -f "$ARCHIVE"
partial="$ARCHIVE.part.$$"
trap 'rm -f "$partial"' EXIT
curl --fail --location --silent --show-error --retry 3 --output "$partial" "$URL"
mv "$partial" "$ARCHIVE"
python3 "$PROJECT_ROOT/scripts/stage-openclash-core.py" "$LOCK" "$ARCHIVE" "$STAGED" "$REPORT"
echo 'OPENCLASH_CORE_FETCH=OFFICIAL_PINNED_SOURCE'
