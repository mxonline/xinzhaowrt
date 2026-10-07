#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mature_sources="$root/production/mature-ui-sources.json"
known_good="$root/config/arthur-known-good.lock"
source_check="$root/scripts/check-package-sources.sh"
packages="$root/scripts/add-custom-packages.sh"
manifest="$root/production/accepted-preview/arthur-adh-quickstart.json"
python_bin="${PYTHON_BIN:-python3}"

# Keep the independently pinned preview source intact, while the firmware
# continues to inherit Stable's official ImmortalWrt LuCI package source.
expected_preview_ref="743bb3ad87a7b97fd440d8e334832e25d4f678e0"
"$python_bin" - "$mature_sources" "$expected_preview_ref" <<'PY'
import json
import sys

path, expected = sys.argv[1:]
sources = json.load(open(path, encoding='utf-8')).get('sources', [])
matches = [source for source in sources if source.get('name') == 'adguardhome']
if len(matches) != 1:
    raise SystemExit('FAIL: preview source manifest must contain exactly one AdGuardHome entry')
source = matches[0]
if source.get('repository') != 'https://github.com/kenzok8/openwrt-packages.git':
    raise SystemExit('FAIL: preview AdGuardHome repository changed')
if source.get('ref') != expected or source.get('subdir') != 'luci-app-adguardhome':
    raise SystemExit('FAIL: preview AdGuardHome source pin changed')
PY

grep -Eq '^LUCI_REF="[0-9a-f]{40}"$' "$known_good" || {
  echo 'FAIL: Stable firmware LuCI source must remain pinned in the Known-Good lock.' >&2
  exit 1
}
grep -Fq 'https://github.com/immortalwrt/luci.git' "$packages" || {
  echo 'FAIL: Stable firmware source preparation must use official ImmortalWrt LuCI.' >&2
  exit 1
}
grep -Fq '"${LUCI_REF:-master}"' "$packages" || {
  echo 'FAIL: firmware LuCI source must use the Known-Good locked ref.' >&2
  exit 1
}
grep -Fq 'luci-app-adguardhome luci-app-autoreboot luci-app-firewall' "$packages" || {
  echo 'FAIL: Stable AdGuardHome LuCI package must remain in the ImmortalWrt application source set.' >&2
  exit 1
}
grep -Fq 'for pkg in luci-app-adguardhome luci-app-autoreboot luci-app-firewall' "$source_check" || {
  echo 'FAIL: package source gate must bind AdGuardHome to the selected official LuCI checkout.' >&2
  exit 1
}
grep -Fq 'assert_source "$pkg" "$IMMORTAL_LUCI_SOURCE/applications/$pkg"' "$source_check" || {
  echo 'FAIL: package source gate must verify the package symlink against the official LuCI checkout.' >&2
  exit 1
}
! grep -Fq 'ADGUARD_MATURE_REF=' "$root/config/istore-quickstart.lock" || {
  echo 'FAIL: LinkEase lock must not absorb a separate AdGuard product source pin.' >&2
  exit 1
}
! grep -Fq 'kenzok8-adguardhome' "$packages" || {
  echo 'FAIL: Stable firmware must not silently switch to a separate AdGuard source.' >&2
  exit 1
}
# Stable owns the existing AdGuard configuration/runtime overlay. Keep it and
# keep AdGuard out of the accepted QuickStart preview overlay.
for path in files/etc/AdGuardHome.yaml files/etc/config/AdGuardHome files/etc/init.d/AdGuardHome; do
  [[ -s "$root/$path" ]] || { echo "FAIL: Stable AdGuard overlay is missing: $path" >&2; exit 1; }
done
"$python_bin" - "$manifest" <<'PY'
import json
import sys

entries = json.load(open(sys.argv[1], encoding='utf-8'))['frozen_files']
adguard_entries = [entry for entry in entries if 'adguardhome' in str(entry.get('source', '')).lower()]
if not adguard_entries:
    raise SystemExit('FAIL: Stable accepted preview lost its frozen AdGuard UI payload')
for entry in adguard_entries:
    if not str(entry.get('source', '')).startswith('sources/live-preview-mature/adguardhome/'):
        raise SystemExit('FAIL: accepted AdGuard preview payload does not use the recorded source tree')
    if not str(entry.get('overlay', '')).startswith('files/'):
        raise SystemExit('FAIL: accepted AdGuard preview payload is not bound to the firmware overlay')
PY

echo 'ADGUARD_SOURCE_OF_TRUTH=PASS'
