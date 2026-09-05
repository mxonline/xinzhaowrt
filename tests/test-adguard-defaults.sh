#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${ADGUARD_MANAGER_PACKAGE_ROOT:-$root/work/immortalwrt/package/feeds/xinzhao/luci-app-adguardhome}"

if [[ -d "$package_root" ]]; then
  config="$package_root/root/etc/config/AdGuardHome"
  [[ -s "$config" ]] || { echo 'FAIL: mature AdGuard Home UCI defaults are missing.' >&2; exit 1; }
  grep -Eq "^[[:space:]]*option enabled '0'[[:space:]]*$" "$config" || { echo 'FAIL: mature AdGuard Home must remain disabled by default for DNS safety.' >&2; exit 1; }
  grep -Eq "^[[:space:]]*option httpport '3000'[[:space:]]*$" "$config" || { echo 'FAIL: mature AdGuard Home Web UI must default to port 3000.' >&2; exit 1; }
  grep -Eq "^[[:space:]]*option redirect 'none'[[:space:]]*$" "$config" || { echo 'FAIL: mature AdGuard Home must not redirect DNS by default.' >&2; exit 1; }
  echo 'PASS: mature AdGuard Home defaults are disabled and DNS-safe.'
else
  PYTHON_BIN="${PYTHON_BIN:-python3}" "$root/tests/test-adguard-source-of-truth.sh"
  echo 'PASS: mature AdGuard Home defaults inherit the locked source-of-truth.'
fi
