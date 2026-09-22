#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_seed() {
  local file="$1" schema="$2"
  grep -Eq "^schema_version: ${schema}$" "$file" || {
    echo "FAIL: expected schema_version ${schema}: ${file}" >&2
    exit 1
  }
  grep -Eq '^clients:[[:space:]]*\[\][[:space:]]*$' "$file" || {
    echo "FAIL: legacy schema seed must use clients: []: ${file}" >&2
    exit 1
  }
  ! grep -q '^  runtime_sources:' "$file" || {
    echo "FAIL: runtime_sources must be created by AdGuardHome migration: ${file}" >&2
    exit 1
  }
  ! grep -q '^  persistent:' "$file" || {
    echo "FAIL: persistent must be created by AdGuardHome migration: ${file}" >&2
    exit 1
  }
}

check_seed "$root/files/etc/AdGuardHome.yaml" 10
check_seed "$root/files/usr/share/AdGuardHome/AdGuardHome_template.yaml" 12
echo 'ADGUARDHOME_LEGACY_SEED_COMPAT=PASS'
