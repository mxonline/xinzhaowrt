#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python

# Reproduce the Linux/CI checkout: materialize Git blobs, not a Windows
# autocrlf-converted worktree. The final-rootfs contract must accept these
# canonical LF bytes.
"$PYTHON_BIN" - "$root" "$fixture" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
fixture = Path(sys.argv[2])
manifest = json.loads((root / 'production/accepted-preview/arthur-adh-quickstart.json').read_text(encoding='utf-8'))
for entry in manifest['frozen_files']:
    if 'quickstart' not in entry['overlay']:
        continue
    result = subprocess.run(
        ['git', '-C', str(root), 'show', f"HEAD:{entry['overlay']}"],
        check=True,
        stdout=subprocess.PIPE,
    )
    target = fixture / entry['remote'].lstrip('/')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(result.stdout)
PY

"$PYTHON_BIN" "$root/scripts/quickstart-template-forensics.py" \
  --root "$root" \
  --manifest "$root/production/accepted-preview/arthur-adh-quickstart.json" \
  --final-rootfs "$fixture" >/dev/null

materialized="$fixture/materialized"
"$PYTHON_BIN" "$root/scripts/materialize-accepted-overlay.py" \
  --root "$root" \
  --manifest "production/accepted-preview/arthur-adh-quickstart.json" \
  --dest "$materialized" >/dev/null
"$PYTHON_BIN" - "$root" "$materialized" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
materialized = Path(sys.argv[2])
manifest = json.loads((root / 'production/accepted-preview/arthur-adh-quickstart.json').read_text(encoding='utf-8'))
for entry in manifest['frozen_files']:
    if 'quickstart' not in entry['overlay']:
        continue
    data = (materialized / Path(entry['overlay']).relative_to('files')).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry['sha256'], entry['overlay']
    if entry.get('line_endings') == 'LF':
        assert b'\r\n' not in data, entry['overlay']
PY

stale_manifest="$fixture/stale-manifest.json"
"$PYTHON_BIN" - "$root" "$stale_manifest" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
target = Path(sys.argv[2])
manifest = json.loads((root / 'production/accepted-preview/arthur-adh-quickstart.json').read_text(encoding='utf-8'))
for entry in manifest['frozen_files']:
    if entry['overlay'] == 'files/usr/lib/lua/luci/view/quickstart/home.htm':
        entry['sha256'] = 'eb0cbda01ef7ea1dba2d4ac5968c6c6fb67133ada00718b97f52f460ceca8f3c'
        break
target.write_text(json.dumps(manifest), encoding='utf-8')
PY

if "$PYTHON_BIN" "$root/scripts/quickstart-template-forensics.py" \
  --root "$root" \
  --manifest "$stale_manifest" \
  --final-rootfs "$fixture" >/dev/null; then
  echo 'FAIL: stale CRLF acceptance contract was accepted' >&2
  exit 1
fi

echo 'QUICKSTART_FINAL_ROOTFS_DRIFT=0'
echo 'QUICKSTART_FINAL_ROOTFS_CONTRACT=PASS'
