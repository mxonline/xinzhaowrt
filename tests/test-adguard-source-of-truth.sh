#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$root/config/arthur-known-good.lock"
packages="$root/scripts/add-custom-packages.sh"
build="$root/scripts/build.sh"
manifest="$root/production/accepted-preview/arthur-quickstart.json"
python_bin="${PYTHON_BIN:-python3}"

grep -Fxq 'ADGUARD_MATURE_REF="743bb3ad87a7b97fd440d8e334832e25d4f678e0"' "$lock" || {
  echo 'FAIL: the mature AdGuard manager must be pinned to the accepted kenzok8 revision.' >&2
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
