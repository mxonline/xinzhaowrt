#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
feed_check_root="${FEED_CHECK_ROOT:?FEED_CHECK_ROOT must point to the prepared source root}"
package_root="${ADGUARD_MANAGER_PACKAGE_ROOT:-$feed_check_root/package/feeds/xinzhao/luci-app-adguardhome}"
feed_view="$package_root/htdocs/luci-static/resources/view/adguardhome/config.js"
feed_acl="$package_root/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
feed_makefile="$package_root/Makefile"
manager_package="$root/package/xinzhao/luci-app-adguardhome-manager/Makefile"
menu="$root/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
controller="$root/files/usr/lib/lua/luci/controller/AdGuardHome.lua"
overview="$root/files/usr/lib/lua/luci/view/AdGuardHome/overview.htm"

for file in "$feed_view" "$feed_acl" "$feed_makefile" "$manager_package" "$menu" "$acl" "$controller" "$overview"; do
  [[ -s "$file" ]] || { echo "FAIL: AdGuard Home manager source missing: $file" >&2; exit 1; }
done

grep -Fq '+adguardhome' "$feed_makefile" || { echo 'FAIL: upstream app package lost its AdGuard Home dependency.' >&2; exit 1; }
grep -Fq '+luci-base' "$feed_makefile" || { echo 'FAIL: upstream app package lost its LuCI dependency.' >&2; exit 1; }
grep -Fq '+luci-app-adguardhome' "$manager_package" || { echo 'FAIL: full manager package must depend on the upstream service UI package.' >&2; exit 1; }
grep -Fq '+luci-compat' "$manager_package" || { echo 'FAIL: full manager package must declare its CBI compatibility dependency.' >&2; exit 1; }
grep -Fq '+rpcd-mod-file' "$manager_package" || { echo 'FAIL: full manager package must declare rpcd file support.' >&2; exit 1; }
grep -qx 'CONFIG_PACKAGE_luci-app-adguardhome-manager=y' "$root/config/arthur.config" || {
  echo 'FAIL: Arthur firmware does not select the full manager package.' >&2
  exit 1
}
grep -Fq 'package/xinzhao/luci-app-adguardhome-manager/' "$root/scripts/build.sh" || {
  echo 'FAIL: build does not stage the full manager package source.' >&2
  exit 1
}
grep -Fq 'luci-app-adguardhome-manager' "$root/scripts/build.sh" && \
grep -Fq 'openclash-core' "$root/scripts/build.sh" && \
grep -Fq './scripts/feeds install -f -p xinzhao' "$root/scripts/build.sh" || {
  echo 'FAIL: firmware-owned manager and Core packages are not installed through the xinzhao feed.' >&2
  exit 1
}

for page in overview base tools log manual; do
  grep -Fq "admin/services/AdGuardHome/$page" "$menu" || { echo "FAIL: full manager menu route missing: $page" >&2; exit 1; }
done
! grep -Fq 'admin/services/adguardhome' "$menu" || { echo 'FAIL: basic lower-case SPA menu overrides the full manager.' >&2; exit 1; }
grep -Fq 'function service_action()' "$controller" || { echo 'FAIL: full manager lifecycle controller missing.' >&2; exit 1; }
for action in start stop restart enable disable; do
  grep -Fq "data-adg-action=\"$action\"" "$overview" || { echo "FAIL: lifecycle button missing: $action" >&2; exit 1; }
done
grep -Fq 'setInitAction' "$acl" || { echo 'FAIL: full manager lifecycle ACL missing.' >&2; exit 1; }
grep -Fq 'getInitList' "$acl" || { echo 'FAIL: full manager service status ACL missing.' >&2; exit 1; }
! grep -Fq 'files/www/luci-static/resources/view/adguardhome/config.js' "$root/production/accepted-preview/arthur-adh-quickstart.json" || {
  echo 'FAIL: simplified feed SPA must not be installed as the project manager overlay.' >&2
  exit 1
}
grep -Fq 'restore-pinned-adguard-manager.sh' "$root/scripts/build.sh" || {
  echo 'FAIL: build does not validate the manager overlay precedence.' >&2
  exit 1
}
grep -Fq 'verify-final-rootfs-adh-manager.py' "$root/scripts/build.sh" || {
  echo 'FAIL: final rootfs manager contract is not a build gate.' >&2
  exit 1
}

echo 'ADGUARD_FULL_MANAGER_SOURCE=PASS'
