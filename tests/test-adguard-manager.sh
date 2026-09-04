#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${ADGUARD_MANAGER_PACKAGE_ROOT:-$root/work/immortalwrt/package/feeds/xinzhao/luci-app-adguardhome}"
controller="$package_root/luasrc/controller/AdGuardHome.lua"
view="$package_root/luasrc/model/cbi/AdGuardHome/overview.lua"
acl="$package_root/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

[[ -s "$view" ]] || { echo 'FAIL: mature AdGuard Home manager view is missing from the pinned feed.' >&2; exit 1; }
[[ -s "$controller" ]] || { echo 'FAIL: mature AdGuard Home controller is missing from the pinned feed.' >&2; exit 1; }
[[ -s "$acl" ]] || { echo 'FAIL: mature AdGuard Home rpcd ACL is missing from the pinned feed.' >&2; exit 1; }

for model in overview base tools log manual; do
  [[ -s "$package_root/luasrc/model/cbi/AdGuardHome/$model.lua" ]] || { echo "FAIL: mature AdGuard CBI model is missing $model." >&2; exit 1; }
done
[[ -s "$package_root/root/etc/config/AdGuardHome" ]] || { echo 'FAIL: mature AdGuard UCI defaults are missing.' >&2; exit 1; }
[[ -s "$package_root/root/etc/AdGuardHome.yaml" ]] || { echo 'FAIL: mature AdGuard YAML is missing.' >&2; exit 1; }
[[ -s "$package_root/root/etc/init.d/AdGuardHome" ]] || { echo 'FAIL: mature AdGuard init script is missing.' >&2; exit 1; }
grep -Fq '"AdGuardHome"' "$acl" || { echo 'FAIL: mature ACL must be scoped to AdGuardHome UCI.' >&2; exit 1; }

echo 'PASS: AdGuard Home uses the pinned mature CBI manager and ACL.'
