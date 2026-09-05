#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "LIVE_PREVIEW_CONTRACT: FAIL -- $*" >&2; exit 1; }

policy="$ROOT/production/live-preview-policy.json"
sources="$ROOT/production/mature-ui-sources.json"
script="$ROOT/scripts/live-preview.ps1"
safe="$ROOT/scripts/live-preview-mature-safe.ps1"
prepare="$ROOT/scripts/prepare-live-preview-sources.ps1"
handoff="$ROOT/scripts/feature-handoff.ps1"
installer="$ROOT/scripts/install-feature-handoff.ps1"
[[ -s "$policy" ]] || fail 'live preview policy missing'
[[ -s "$sources" ]] || fail 'mature UI source lock missing'
[[ -s "$script" ]] || fail 'live preview executor missing'
[[ -s "$safe" ]] || fail 'safe mature preview wrapper missing'
[[ -s "$prepare" ]] || fail 'mature source preparation script missing'
[[ -s "$handoff" ]] || fail 'feature handoff executor missing'
[[ -s "$installer" ]] || fail 'feature handoff installer missing'

grep -Fq 'WIFI=VERIFIED_FROZEN' "$safe" || fail 'Wi-Fi frozen marker missing from safe wrapper'
grep -Fq 'REAL_DEVICE_VERIFY=NOT_RUN' "$safe" || fail 'safe preview must not claim formal real-device verification'
grep -Fq 'RELEASE_ALLOWED=false' "$safe" || fail 'safe preview must never allow release'
grep -Fq 'LIVE_PREVIEW=FAIL_ROLLED_BACK' "$safe" || fail 'safe wrapper rollback marker missing'
grep -Fq 'ADGUARD_UI_PREVIEW=PASS' "$safe" || fail 'AdGuard UI preview marker missing'
grep -Fq 'ADGUARD_NETWORK_MUTATION_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY' "$safe" || fail 'unsafe ADH runtime test must defer automatically'
grep -Fq 'ADGUARD_WEB_RUNTIME_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY' "$safe" || fail 'ADH runtime web test must defer automatically'
grep -Fq 'QUICKSTART_PREVIEW=PASS' "$safe" || fail 'QuickStart preview marker missing'
grep -Fq 'Invoke-AuthenticatedLuciPage' "$safe" || fail 'authenticated LuCI check missing from safe wrapper'
grep -Fq 'live-preview.ps1' "$safe" || fail 'safe wrapper must reuse the generic deploy executor'
grep -Fq 'Generic' "$safe" || fail 'safe wrapper must use Generic deploy mode'
grep -Fq 'FeatureId' "$safe" || fail 'safe preview must pass durable feature identity'
grep -Fq 'PauseAfterLivePreview' "$safe" || fail 'post-preview pause must be explicit'
grep -Fq 'FEATURE_HANDOFF_STARTED=' "$safe" || fail 'successful preview must start durable handoff by default'
grep -Fq 'feature-handoff.ps1' "$safe" || fail 'safe preview must invoke feature handoff executor'
grep -Fq 'PRODUCTION_RELEASED' "$handoff" || fail 'handoff must continue to sole production terminal state'
grep -Fq 'arthur-update-v3.yml' "$handoff" || fail 'handoff must reuse existing v3 Candidate workflow'

grep -Fq 'allowed_remote_exact' "$script" || fail 'exact-path safety exception support missing'
grep -Fq 'Mode' "$script" || fail 'per-file mode support missing'
grep -Fq '/etc/init.d/AdGuardHome' "$script" || fail 'mature AdGuard init path missing'
grep -Fq 'style.css' "$safe" || fail 'QuickStart stylesheet completeness check missing'
grep -Fq 'vendor.js' "$safe" || fail 'QuickStart vendor bundle completeness check missing'

! grep -Eq 'uci[[:space:]]+(set|delete|rename)[[:space:]]+wireless|wifi[[:space:]]+(reload|down|up)' "$safe" || fail 'safe preview contains Wi-Fi mutation'
! grep -Eq '/sbin/sysupgrade|(^|[^[:alnum:]_])mtd([^[:alnum:]_]|$)|dd[[:space:]].*of=/dev/' "$safe" || fail 'safe preview contains flash/raw-write operation'
! grep -Eq '/etc/init\.d/AdGuardHome[[:space:]]+(start|stop|restart|reload|enable|disable)' "$safe" || fail 'safe preview must not invoke mature AdGuard init mutations'
! grep -Eq 'uci[[:space:]].*(dhcp|firewall)|iptables|ip6tables|nft[[:space:]]' "$safe" || fail 'safe preview must not mutate DNS/firewall runtime'
! grep -Eqi 'push[[:space:]]+--force|reset[[:space:]]+--hard|clean[[:space:]]+-fdx' "$handoff" || fail 'feature handoff contains destructive Git operation'

python - "$policy" "$sources" <<'PY'
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

echo 'PASS: LIVE_PREVIEW mature UI safe-fallback and production handoff contract is present.'
