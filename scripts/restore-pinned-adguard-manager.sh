#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
PACKAGE_ROOT="$SRC/package/feeds/xinzhao/luci-app-adguardhome/root"

# The accepted legacy bundle contains files at these same rootfs paths.  The
# pinned ImmortalWrt package is authoritative for the mature lowercase view
# registration and its matching rpcd permissions.
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
