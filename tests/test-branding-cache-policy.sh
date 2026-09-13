#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${BRANDING_SOURCE:-$ROOT/files/www/luci-static/xinzhao/branding.js}"

[[ -f "$SOURCE" ]] || {
  echo "FAIL: branding source is missing: $SOURCE" >&2
  exit 1
}

grep -Eq "fetch\('/luci-static/xinzhao/build-info\.json', *\{[^}]*cache: *['\"]no-store['\"]" "$SOURCE" || {
  echo 'FAIL: status card build-info fetch is cacheable and can retain placeholders' >&2
  exit 1
}

echo 'PASS: status card fetches build identity without browser cache'
