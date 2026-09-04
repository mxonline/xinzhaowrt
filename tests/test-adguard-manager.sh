#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
menu="$root/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
[[ ! -e "$root/files/www/luci-static/resources/view/adguardhome/config.js" ]] || { echo 'FAIL: obsolete custom AdGuard manager overlay remains.' >&2; exit 1; }
for page in overview base tools log manual; do
  grep -Fq "AdGuardHome/$page" "$menu" || { echo "FAIL: mature AdGuard menu is missing $page." >&2; exit 1; }
done
for model in overview base tools log manual; do
  [[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/$model.lua" ]] || { echo "FAIL: mature AdGuard CBI model is missing $model." >&2; exit 1; }
done
acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
[[ -s "$acl" ]] || { echo 'FAIL: AdGuard Home rpcd ACL is missing.' >&2; exit 1; }
grep -Fq '"AdGuardHome"' "$acl" || { echo 'FAIL: ACL does not grant mature AdGuard UCI access.' >&2; exit 1; }
echo 'PASS: AdGuard Home full manager static contract.'
