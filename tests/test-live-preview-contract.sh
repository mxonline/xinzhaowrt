#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "LIVE_PREVIEW_CONTRACT: FAIL -- $*" >&2; exit 1; }

policy="$ROOT/production/live-preview-policy.json"
sources="$ROOT/production/mature-ui-sources.json"
script="$ROOT/scripts/live-preview.ps1"
prepare="$ROOT/scripts/prepare-live-preview-sources.ps1"
[[ -s "$policy" ]] || fail 'live preview policy missing'
[[ -s "$sources" ]] || fail 'mature UI source lock missing'
[[ -s "$script" ]] || fail 'live preview executor missing'
[[ -s "$prepare" ]] || fail 'mature source preparation script missing'

grep -Fq 'WIFI=VERIFIED_FROZEN' "$script" || fail 'Wi-Fi frozen marker missing'
grep -Fq 'REAL_DEVICE_VERIFY=NOT_RUN' "$script" || fail 'preview must not claim formal real-device verification'
grep -Fq 'RELEASE_ALLOWED=false' "$script" || fail 'preview must never allow release'
grep -Fq 'LIVE_PREVIEW=FAIL_ROLLED_BACK' "$script" || fail 'automatic rollback marker missing'
grep -Fq 'xinzhaowrt-live-preview' "$script" || fail 'router-side backup root missing'
grep -Fq 'Invoke-AuthenticatedLuciPage' "$script" || fail 'authenticated LuCI check missing'
grep -Fq 'Test-AdGuardPreview' "$script" || fail 'AdGuard preview check missing'
grep -Fq 'Test-QuickStartPreview' "$script" || fail 'QuickStart preview check missing'
grep -Fq 'allowed_remote_exact' "$script" || fail 'exact-path safety exception support missing'
grep -Fq 'Mode' "$script" || fail 'per-file mode support missing'
grep -Fq '/etc/init.d/AdGuardHome' "$script" || fail 'mature AdGuard init path missing'
grep -Fq 'style.css' "$script" || fail 'QuickStart stylesheet completeness check missing'
grep -Fq 'vendor.js' "$script" || fail 'QuickStart vendor bundle completeness check missing'

! grep -Eq 'uci[[:space:]]+(set|delete|rename)[[:space:]]+wireless|wifi[[:space:]]+(reload|down|up)' "$script" || fail 'preview script contains Wi-Fi mutation'
! grep -Eq '/sbin/sysupgrade|(^|[^[:alnum:]_])mtd([^[:alnum:]_]|$)|dd[[:space:]].*of=/dev/' "$script" || fail 'preview script contains flash/raw-write operation'

python3 - "$policy" "$sources" <<'PY'
import json, sys
p=json.load(open(sys.argv[1], encoding='utf-8'))
s=json.load(open(sys.argv[2], encoding='utf-8'))
assert p['schema_version'] == 1
assert p['device']['management_ip'] == '192.168.6.1'
assert '/etc/config/wireless' in p['forbidden_remote_prefixes']
assert '/etc/config/network' in p['forbidden_remote_prefixes']
assert '/etc/init.d/' in p['forbidden_remote_prefixes']
assert '/www/luci-static/' in p['allowed_remote_prefixes']
assert '/www/' not in p['allowed_remote_prefixes']
assert '/usr/share/rpcd/acl.d/' in p['allowed_remote_prefixes']
assert '/usr/share/AdGuardHome/' in p['allowed_remote_prefixes']
assert '/usr/lib/lua/luci/model/cbi/AdGuardHome/' in p['allowed_remote_prefixes']
assert '/usr/lib/lua/luci/view/AdGuardHome/' in p['allowed_remote_prefixes']
assert '/usr/lib/lua/luci/view/quickstart/' in p['allowed_remote_prefixes']
exact=set(p['allowed_remote_exact'])
for path in [
    '/etc/init.d/AdGuardHome',
    '/etc/config/AdGuardHome',
    '/etc/AdGuardHome.yaml',
    '/usr/lib/lua/luci/controller/AdGuardHome.lua',
    '/usr/lib/lua/luci/controller/quickstart.lua',
    '/usr/lib/lua/luci/controller/istore_backend.lua',
]:
    assert path in exact, path
assert p['adguard_route'] == 'admin/services/AdGuardHome/overview'
assert p['quickstart_route'] == 'admin/quickstart/'
assert s['schema_version'] == 1
assert s['staging_root'] == 'sources/live-preview-mature'
by_name={x['name']:x for x in s['sources']}
assert by_name['adguardhome']['repository'] == 'https://github.com/kenzok8/openwrt-packages.git'
assert by_name['adguardhome']['ref'] == '743bb3ad87a7b97fd440d8e334832e25d4f678e0'
assert by_name['adguardhome']['subdir'] == 'luci-app-adguardhome'
assert by_name['quickstart']['repository'] == 'https://github.com/linkease/nas-packages-luci.git'
assert by_name['quickstart']['ref'] == '7e5083e2ca4cfa4d31f312026f46e5213c5b03f5'
assert by_name['quickstart']['subdir'] == 'luci/luci-app-quickstart'
PY

echo 'PASS: LIVE_PREVIEW mature UI safety contract is present.'
