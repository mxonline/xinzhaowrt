#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${ADGUARD_MANAGER_PACKAGE_ROOT:-$root/work/immortalwrt/package/feeds/xinzhao/luci-app-adguardhome}"
view="$package_root/htdocs/luci-static/resources/view/adguardhome/config.js"
acl="$package_root/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
overlay_view="$root/files/www/luci-static/resources/view/adguardhome/config.js"
overlay_acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

[[ ! -e "$overlay_view" ]] || { echo 'FAIL: project overlay must not replace the mature AdGuard Home manager.' >&2; exit 1; }
if [[ -e "$overlay_acl" ]]; then
  grep -Fq 'files/usr/share/rpcd/acl.d/luci-app-adguardhome.json' "$root/production/accepted-preview/arthur-adh-quickstart.json" || {
    echo 'FAIL: legacy AdGuard ACL overlay is not part of the accepted bundle.' >&2
    exit 1
  }
  grep -Fq 'restore-pinned-adguard-manager.sh' "$root/scripts/build.sh" || {
    echo 'FAIL: accepted legacy ACL must be superseded by the pinned mature manager during build.' >&2
    exit 1
  }
fi
[[ -s "$view" ]] || { echo 'FAIL: mature AdGuard Home manager view is missing from the pinned feed.' >&2; exit 1; }
[[ -s "$acl" ]] || { echo 'FAIL: mature AdGuard Home rpcd ACL is missing from the pinned feed.' >&2; exit 1; }

for marker in "form.Map('adguardhome'" 'form.TypedSection' "object: 'service'" "method: 'list'" 'poll.add' 'fs.exec'; do
  grep -Fq "$marker" "$view" || { echo "FAIL: mature AdGuard manager marker missing: $marker" >&2; exit 1; }
done
! grep -Fq 'getInitList' "$view" || { echo 'FAIL: obsolete custom lifecycle RPC remains in the manager.' >&2; exit 1; }
! grep -Fq 'setInitAction' "$view" || { echo 'FAIL: obsolete custom lifecycle RPC remains in the manager.' >&2; exit 1; }

grep -Fq '"service"' "$acl" || { echo 'FAIL: upstream ACL must grant service.list.' >&2; exit 1; }
grep -Fq '"uci"' "$acl" || { echo 'FAIL: upstream ACL must grant UCI access.' >&2; exit 1; }
grep -Fq '"adguardhome"' "$acl" || { echo 'FAIL: upstream ACL must be scoped to adguardhome.' >&2; exit 1; }
grep -Fq 'AdGuardHome --version' "$acl" || { echo 'FAIL: upstream ACL must grant version discovery.' >&2; exit 1; }

echo 'PASS: AdGuard Home uses the pinned mature manager and upstream ACL.'
