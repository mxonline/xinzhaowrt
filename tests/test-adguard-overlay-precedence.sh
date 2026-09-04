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
  "$src/files/usr/share/rpcd/acl.d"

printf '%s\n' 'mature-lowercase-view' > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' 'mature-service-list-acl' > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
printf '%s\n' 'legacy-uppercase-cbi' > "$src/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' 'legacy-custom-rpc' > "$src/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

bash "$root/scripts/restore-pinned-adguard-manager.sh" "$src"

grep -Fxq 'mature-lowercase-view' "$src/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
grep -Fxq 'mature-service-list-acl' "$src/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
echo 'ADGUARD_OVERLAY_PRECEDENCE=PASS'
