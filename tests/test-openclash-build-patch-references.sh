#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/add-custom-packages.sh"
mapfile -t references < <(grep -oE 'patches/openclash/[A-Za-z0-9._-]+\.patch' "$SCRIPT" | sort -u)

for reference in "${references[@]}"; do
  [[ -f "$ROOT/$reference" ]] || {
    echo "FEED_PATCH_REFERENCE=FAIL missing $reference" >&2
    exit 1
  }
done

echo 'FEED_PATCH_REFERENCES=PASS'
