#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATUS_FILE="production/status.json"
STABLE_TAG="${1:?stable tag required}"
CANDIDATE_TAG="${2:?candidate tag required}"
FIRMWARE="${3:?firmware name required}"
SHA256="${4:?firmware sha256 required}"
SOURCE_COMMIT="${5:?source commit required}"

python3 - "$STATUS_FILE" "$STABLE_TAG" "$CANDIDATE_TAG" "$FIRMWARE" "$SHA256" "$SOURCE_COMMIT" <<'PY'
import json, sys
from datetime import datetime, timezone
path, stable_tag, candidate_tag, firmware, sha256, source_commit = sys.argv[1:]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}
data.update({
    'status': 'verified',
    'stage': 'stable_release',
    'conclusion': 'success',
    'device': 'jdcloud_re-ss-01',
    'candidate_tag': candidate_tag,
    'stable_tag': stable_tag,
    'source_commit': source_commit,
    'firmware': firmware,
    'sha256': sha256,
    'known_good': True,
    'message': 'Stable GitHub Release published after explicit real-device verification; known-good updated.',
    'updated_at': datetime.now(timezone.utc).isoformat()
})
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
