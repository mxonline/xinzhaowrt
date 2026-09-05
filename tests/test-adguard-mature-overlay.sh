#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy="$root/files/www/luci-static/resources/view/adguardhome/config.js"
menu="$root/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
source_acl="$root/sources/live-preview-mature/adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
overlay_acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

[[ ! -e "$legacy" ]] || { echo 'FAIL: obsolete custom AdGuard manager overlay still shadows the mature package surface.' >&2; exit 1; }
for page in overview base tools log manual; do
  grep -Fq "AdGuardHome/$page" "$menu" || { echo "FAIL: mature AdGuard menu is missing $page." >&2; exit 1; }
done
[[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/overview.lua" ]] || { echo 'FAIL: mature overview CBI model is missing.' >&2; exit 1; }
[[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua" ]] || { echo 'FAIL: mature base CBI model is missing.' >&2; exit 1; }
[[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/tools.lua" ]] || { echo 'FAIL: mature tools CBI model is missing.' >&2; exit 1; }
[[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/log.lua" ]] || { echo 'FAIL: mature log model is missing.' >&2; exit 1; }
[[ -s "$root/files/usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua" ]] || { echo 'FAIL: mature manual CBI model is missing.' >&2; exit 1; }
python - "$source_acl" "$overlay_acl" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    source = json.load(f)
with open(sys.argv[2], encoding='utf-8') as f:
    overlay = json.load(f)
if source != overlay:
    raise SystemExit('FAIL: AdGuard ACL diverges from the pinned mature package.')
PY
echo 'ADGUARD_MATURE_OVERLAY=PASS'
