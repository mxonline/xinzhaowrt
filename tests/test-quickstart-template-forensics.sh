#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/usr/lib/lua/luci/view/quickstart"

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || PYTHON_BIN=python
"$PYTHON_BIN" - "$root" "$fixture" <<'PY'
import json
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
fixture = Path(sys.argv[2])
manifest = json.loads((root / 'production/accepted-preview/arthur-adh-quickstart.json').read_text(encoding='utf-8'))
for entry in manifest['frozen_files']:
    source = root / entry['overlay']
    target = fixture / entry['remote'].lstrip('/')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
PY
"$PYTHON_BIN" "$root/scripts/quickstart-template-forensics.py" \
  --root "$root" \
  --manifest "$root/production/accepted-preview/arthur-adh-quickstart.json" \
  --final-rootfs "$fixture"

echo 'QUICKSTART_TEMPLATE_FORENSICS=PASS'
