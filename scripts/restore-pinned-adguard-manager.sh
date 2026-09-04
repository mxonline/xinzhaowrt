#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
PACKAGE_ROOT="$SRC/package/feeds/xinzhao/luci-app-adguardhome/root"

# The accepted preview proved the feature set on a live router, but its older
# uppercase Lua/CBI manager must never override or coexist with the pinned
# mature lowercase LuCI manager in a production image.  Keep service/runtime
# payloads that are not manager registrations, and remove only conflicting UI,
# UCI/init aliases and the obsolete placeholder view from the final overlay.
for obsolete in \
  usr/lib/lua/luci/controller/AdGuardHome.lua \
  usr/lib/lua/luci/model/cbi/AdGuardHome \
  usr/lib/lua/luci/view/AdGuardHome \
  etc/config/AdGuardHome \
  etc/init.d/AdGuardHome \
  www/luci-static/resources/view/luci-app-adguardhome/index.js; do
  rm -rf "$SRC/files/$obsolete"
done

# The pinned ImmortalWrt package is authoritative for mature lowercase route
# registration and matching rpcd permissions.  Copy these two files back into
# the overlay after the accepted bundle is materialized so package/overlay
# precedence cannot regress them to the legacy manager.
for relative in \
  usr/share/luci/menu.d/luci-app-adguardhome.json \
  usr/share/rpcd/acl.d/luci-app-adguardhome.json; do
  source="$PACKAGE_ROOT/$relative"
  destination="$SRC/files/$relative"
  [[ -s "$source" ]] || {
    echo "ERROR: pinned AdGuard manager file is missing: $source" >&2
    exit 1
  }
  mkdir -p "$(dirname "$destination")"
  cp -p "$source" "$destination"
done

echo 'ADGUARD_MANAGER_OVERLAY_SOURCE=PINNED_IMMORTALWRT_FEED'
echo 'ADGUARD_LEGACY_MANAGER_PURGE=PASS'
