#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FUNCTIONAL_ACCEPTANCE: FAIL -- $*" >&2; exit 1; }

acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
menu="$root/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
luci_defaults="$root/files/etc/uci-defaults/97-xinzhao-luci-defaults"
verify="$root/scripts/real-device-verify.ps1"
verify_v3="$root/scripts/real-device-verify-v3.ps1"
safety="$root/scripts/auto-flash-safety-gate.ps1"
workflow="$root/.github/workflows/arthur-update-v3.yml"
rejection="$root/production/candidate-rejection-33569029385.json"

[[ -s "$acl" ]] || fail 'AdGuard Home rpcd ACL is missing'
[[ ! -e "$root/files/www/luci-static/resources/view/adguardhome/config.js" ]] || fail 'obsolete custom AdGuard manager overlay remains'
for page in overview base tools log manual; do
  grep -Fq "AdGuardHome/$page" "$menu" || fail "mature AdGuard menu is missing $page"
  [[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/$page.lua" ]] || fail "mature AdGuard CBI model is missing $page"
done

grep -Fq '"AdGuardHome"' "$acl" || fail 'AdGuard mature UCI ACL permission is missing'

grep -Fq "homepage='admin/quickstart'" "$luci_defaults" || fail 'LuCI default homepage is not iStore QuickStart'
grep -Fq '/cgi-bin/luci/admin/quickstart' "$verify" || fail 'real-device verifier does not exercise the iStore QuickStart homepage route'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device verifier does not require rendered QuickStart frontend assets'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device verifier does not require functional QuickStart homepage rendering'
grep -Fq 'adguard_rpc_functional' "$verify" || fail 'real-device verifier does not require authenticated AdGuard management access'
grep -Fq '33569029385' "$verify_v3" || fail 'pre-fix run must be refused by functional real-device verification'

[[ -s "$rejection" ]] || fail 'pre-fix production run must have durable rejection evidence'
grep -Fq '33569029385' "$rejection" || fail 'rejection evidence must identify the pre-fix run'
grep -Fq 'REJECTED_FOR_RELEASE' "$rejection" || fail 'pre-fix run must be rejected for release'
grep -Fq 'candidate-rejection-' "$safety" || fail 'existing AUTO_FLASH_SAFETY_GATE must enforce durable candidate rejection evidence'

grep -Fq "status not in {'verified', 'frozen'}" "$workflow" || fail 'formal workflow must accept the authoritative frozen verified Known-Good state'

echo 'FUNCTIONAL_ACCEPTANCE=PASS'
