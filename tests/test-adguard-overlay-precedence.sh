#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

src="$tmp/immortalwrt"
mkdir -p \
  "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/luci/menu.d" \
  "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/rpcd/acl.d" \
  "$src/files/usr/share/luci/menu.d" \
  "$src/files/usr/share/rpcd/acl.d" \
  "$src/files/usr/lib/lua/luci/controller" \
  "$src/files/usr/lib/lua/luci/model/cbi/AdGuardHome" \
  "$src/files/usr/lib/lua/luci/view/AdGuardHome" \
  "$src/files/etc/config" \
  "$src/files/etc/init.d" \
  "$src/files/www/luci-static/resources/view/luci-app-adguardhome"

printf '%s\n' 'mature-lowercase-view' > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' 'mature-service-list-acl' > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
printf '%s\n' 'legacy-uppercase-cbi' > "$src/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' 'legacy-custom-rpc' > "$src/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
printf '%s\n' 'legacy-controller' > "$src/files/usr/lib/lua/luci/controller/AdGuardHome.lua"
printf '%s\n' 'legacy-cbi' > "$src/files/usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua"
printf '%s\n' 'legacy-view' > "$src/files/usr/lib/lua/luci/view/AdGuardHome/overview.htm"
printf '%s\n' 'legacy-config' > "$src/files/etc/config/AdGuardHome"
printf '%s\n' 'legacy-init' > "$src/files/etc/init.d/AdGuardHome"
printf '%s\n' 'stale-placeholder' > "$src/files/www/luci-static/resources/view/luci-app-adguardhome/index.js"

bash "$root/scripts/restore-pinned-adguard-manager.sh" "$src"

grep -Fxq 'mature-lowercase-view' "$src/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
grep -Fxq 'mature-service-list-acl' "$src/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

for obsolete in \
  "$src/files/usr/lib/lua/luci/controller/AdGuardHome.lua" \
  "$src/files/usr/lib/lua/luci/model/cbi/AdGuardHome" \
  "$src/files/usr/lib/lua/luci/view/AdGuardHome" \
  "$src/files/etc/config/AdGuardHome" \
  "$src/files/etc/init.d/AdGuardHome" \
  "$src/files/www/luci-static/resources/view/luci-app-adguardhome/index.js"; do
  [[ ! -e "$obsolete" ]] || {
    echo "FAIL: obsolete AdGuard manager overlay survived production normalization: $obsolete" >&2
    exit 1
  }
done

echo 'ADGUARD_OVERLAY_PRECEDENCE=PASS'
echo 'ADGUARD_LEGACY_MANAGER_PURGE=PASS'
