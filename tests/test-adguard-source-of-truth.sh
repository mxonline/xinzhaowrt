#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mature_sources="$root/production/mature-ui-sources.json"
build_sources="$root/config/istore-quickstart.lock"
packages="$root/scripts/add-custom-packages.sh"
build="$root/scripts/build.sh"
manifest="$root/production/accepted-preview/arthur-quickstart.json"
python_bin="${PYTHON_BIN:-python3}"

expected_ref="743bb3ad87a7b97fd440d8e334832e25d4f678e0"

"$python_bin" - "$mature_sources" "$expected_ref" <<'PY'
import json
import sys

path, expected = sys.argv[1:]
data = json.load(open(path, encoding='utf-8'))
matches = [s for s in data.get('sources', []) if s.get('name') == 'adguardhome']
if len(matches) != 1:
    raise SystemExit('FAIL: mature-ui-sources.json must contain exactly one adguardhome source')
source = matches[0]
if source.get('repository') != 'https://github.com/kenzok8/openwrt-packages.git':
    raise SystemExit('FAIL: mature AdGuard repository is not the accepted kenzok8 source')
if source.get('ref') != expected:
    raise SystemExit('FAIL: mature AdGuard ref differs from the accepted revision')
if source.get('subdir') != 'luci-app-adguardhome':
    raise SystemExit('FAIL: mature AdGuard source subdir is incorrect')
PY

grep -Fxq "ADGUARD_MATURE_REF=\"$expected_ref\"" "$build_sources" || {
  echo 'FAIL: mature AdGuard production build pin must match mature-ui-sources.json.' >&2
  exit 1
}
! grep -Fq 'ADGUARD_MATURE_REF=' "$root/config/arthur-known-good.lock" || {
  echo 'FAIL: mature AdGuard feature pin must not mutate the immutable Known-Good lock.' >&2
  exit 1
}
grep -Fq 'kenzok8-adguardhome' "$packages" || {
  echo 'FAIL: source preparation must fetch the dedicated pinned mature AdGuard source.' >&2
  exit 1
}
grep -Fq 'link_pkg luci-app-adguardhome "$ADGUARD_MATURE/luci-app-adguardhome"' "$packages" || {
  echo 'FAIL: luci-app-adguardhome must be linked from the accepted mature source.' >&2
  exit 1
}
! grep -Fq 'restore-pinned-adguard-manager.sh' "$build" || {
  echo 'FAIL: build must not restore a duplicate AdGuard manager overlay.' >&2
  exit 1
}

for legacy in \
  files/etc/AdGuardHome.yaml \
  files/etc/config/AdGuardHome \
  files/etc/init.d/AdGuardHome \
  files/usr/lib/lua/luci/i18n/adguardhome.zh-cn.lmo \
  files/usr/lib/lua/luci/controller/AdGuardHome.lua \
  files/usr/lib/lua/luci/model/cbi/AdGuardHome \
  files/usr/lib/lua/luci/view/AdGuardHome \
  files/usr/share/luci/menu.d/luci-app-adguardhome.json \
  files/usr/share/rpcd/acl.d/luci-app-adguardhome.json \
  files/www/luci-static/resources/view/luci-app-adguardhome; do
  if [[ -d "$root/$legacy" ]]; then
    [[ -z "$(find "$root/$legacy" -type f -print -quit)" ]] || {
      echo "FAIL: obsolete AdGuard overlay remains: $legacy" >&2
      exit 1
    }
  else
    [[ ! -e "$root/$legacy" ]] || {
      echo "FAIL: obsolete AdGuard overlay remains: $legacy" >&2
      exit 1
    }
  fi
done

"$python_bin" - "$manifest" <<'PY'
import json
import sys

entries = json.load(open(sys.argv[1], encoding='utf-8'))['frozen_files']
for entry in entries:
    joined = ' '.join(str(entry.get(key, '')) for key in ('source', 'remote', 'overlay')).lower()
    if 'adguardhome' in joined:
        raise SystemExit('FAIL: accepted overlay still materializes an AdGuard manager file')
PY

echo 'ADGUARD_SOURCE_OF_TRUTH=PASS'
