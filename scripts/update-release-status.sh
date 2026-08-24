#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATUS_FILE="production/status.json"
TAG="${1:?candidate tag required}"
FIRMWARE="${2:?firmware name required}"
SHA256="${3:?firmware sha256 required}"
RUN_ID="${GITHUB_RUN_ID:-unknown}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-mxonline/xinzhaowrt}/actions/runs/${RUN_ID}"

python3 - "$STATUS_FILE" "$TAG" "$FIRMWARE" "$SHA256" "$RUN_ID" "$RUN_URL" <<'PY'
import json, sys
from datetime import datetime, timezone
path, tag, firmware, sha256, run_id, run_url = sys.argv[1:]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}
data.update({
    'status': 'candidate_published',
    'stage': 'release',
    'conclusion': 'success',
    'device': 'jdcloud_re-ss-01',
    'candidate_tag': tag,
    'firmware': firmware,
    'sha256': sha256,
    'build_run_id': run_id,
    'build_run_url': run_url,
    'known_good': False,
    'message': 'Candidate GitHub Release published. Waiting for real-device verification before Stable/known-good promotion.',
    'updated_at': datetime.now(timezone.utc).isoformat()
})
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
