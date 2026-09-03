#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "LIVE_PREVIEW_CONTRACT: FAIL -- $*" >&2; exit 1; }

policy="$ROOT/production/live-preview-policy.json"
script="$ROOT/scripts/live-preview.ps1"
[[ -s "$policy" ]] || fail 'live preview policy missing'
[[ -s "$script" ]] || fail 'live preview executor missing'

grep -Fq 'WIFI=VERIFIED_FROZEN' "$script" || fail 'Wi-Fi frozen marker missing'
grep -Fq 'REAL_DEVICE_VERIFY=NOT_RUN' "$script" || fail 'preview must not claim formal real-device verification'
grep -Fq 'RELEASE_ALLOWED=false' "$script" || fail 'preview must never allow release'
grep -Fq 'LIVE_PREVIEW=FAIL_ROLLED_BACK' "$script" || fail 'automatic rollback marker missing'
grep -Fq 'xinzhaowrt-live-preview' "$script" || fail 'router-side backup root missing'
grep -Fq 'Invoke-AuthenticatedLuciPage' "$script" || fail 'authenticated LuCI check missing'
grep -Fq 'Test-AdGuardPreview' "$script" || fail 'AdGuard preview check missing'
grep -Fq 'Test-QuickStartPreview' "$script" || fail 'QuickStart preview check missing'

! grep -Eq 'uci[[:space:]]+(set|delete|rename)[[:space:]]+wireless|wifi[[:space:]]+(reload|down|up)' "$script" || fail 'preview script contains Wi-Fi mutation'
! grep -Eq '/sbin/sysupgrade|(^|[^[:alnum:]_])mtd([^[:alnum:]_]|$)|dd[[:space:]].*of=/dev/' "$script" || fail 'preview script contains flash/raw-write operation'

python3 - "$policy" <<'PY'
import json, sys
p=json.load(open(sys.argv[1], encoding='utf-8'))
assert p['schema_version'] == 1
assert p['device']['management_ip'] == '192.168.6.1'
assert '/etc/config/wireless' in p['forbidden_remote_prefixes']
assert '/etc/config/network' in p['forbidden_remote_prefixes']
assert '/www/luci-static/' in p['allowed_remote_prefixes']
assert '/www/' not in p['allowed_remote_prefixes']
assert '/usr/share/rpcd/acl.d/' in p['allowed_remote_prefixes']
PY

echo 'PASS: LIVE_PREVIEW safety contract is present.'
