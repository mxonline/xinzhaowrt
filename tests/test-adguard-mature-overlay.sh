#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="$root/files/usr/share/AdGuardHome"
packages="$root/scripts/add-custom-packages.sh"
patch="$root/scripts/patch-adguardhome-coexistence.py"
[[ ! -d "$overlay" ]] || [[ -z "$(find "$overlay" -type f -print -quit)" ]] || {
  echo 'FAIL: project overlay still shadows the pinned mature AdGuard package.' >&2
  exit 1
}
grep -Fq 'link_pkg luci-app-adguardhome "$ADGUARD_MATURE/luci-app-adguardhome"' "$packages" || {
  echo 'FAIL: mature AdGuard manager is not sourced from the pinned package.' >&2
  exit 1
}
grep -Fq 'patch-adguardhome-coexistence.py' "$packages" || {
  echo 'FAIL: mature AdGuard template is not patched at package staging time.' >&2
  exit 1
}
grep -Fq '127.0.0.1:7874' "$patch" || {
  echo 'FAIL: mature AdGuard template patch does not terminate at OpenClash DNS 7874.' >&2
  exit 1
}
grep -Fq 'port: 1745' "$patch" || {
  echo 'FAIL: mature AdGuard template patch does not enforce DNS port 1745.' >&2
  exit 1
}
echo 'ADGUARD_MATURE_OVERLAY=PASS'
