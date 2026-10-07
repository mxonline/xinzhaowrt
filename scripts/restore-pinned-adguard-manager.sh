#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
PACKAGE_ROOT="${ADGUARD_MANAGER_PACKAGE_ROOT:-$SRC/package/feeds/xinzhao/luci-app-adguardhome}"
OVERLAY="$SRC/files"

fail() {
  echo "ADGUARD_MANAGER_SOURCE_CHECK=FAIL -- $*" >&2
  exit 1
}

[[ -f "$PACKAGE_ROOT/Makefile" ]] || fail "pinned luci-app-adguardhome package is missing: $PACKAGE_ROOT/Makefile"
[[ -s "$PACKAGE_ROOT/htdocs/luci-static/resources/view/adguardhome/config.js" ]] || \
  fail 'pinned luci-app-adguardhome feed source is incomplete'
grep -Fq '+adguardhome' "$PACKAGE_ROOT/Makefile" || fail 'luci-app-adguardhome must depend on adguardhome'
grep -Fq '+luci-base' "$PACKAGE_ROOT/Makefile" || fail 'luci-app-adguardhome must depend on luci-base'

menu="$OVERLAY/usr/share/luci/menu.d/luci-app-adguardhome.json"
acl="$OVERLAY/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
controller="$OVERLAY/usr/lib/lua/luci/controller/AdGuardHome.lua"
overview="$OVERLAY/usr/lib/lua/luci/view/AdGuardHome/overview.htm"
uci="$OVERLAY/etc/config/AdGuardHome"
init="$OVERLAY/etc/init.d/AdGuardHome"

for file in "$menu" "$acl" "$controller" "$overview" "$uci" "$init"; do
  [[ -s "$file" ]] || fail "full manager overlay file is missing: ${file#"$OVERLAY"/}"
done

for page in overview base tools log manual; do
  grep -Fq "admin/services/AdGuardHome/$page" "$menu" || fail "menu route is missing: $page"
done
! grep -Fq 'admin/services/adguardhome' "$menu" || \
  fail 'lowercase upstream SPA route must not replace the full CBI manager route'
grep -Fq 'function service_action()' "$controller" || fail 'lifecycle controller action is missing'
for action in start stop restart enable disable; do
  grep -Fq "$action = \"$action\"" "$controller" || fail "lifecycle action is missing: $action"
  grep -Fq "data-adg-action=\"$action\"" "$overview" || fail "lifecycle button is missing: $action"
done
grep -Fq 'setInitAction' "$acl" || fail 'rpcd ACL is missing init service control permission'
grep -Fq 'getInitList' "$acl" || fail 'rpcd ACL is missing init status permission'
grep -Fq "option enabled '0'" "$uci" || fail 'AdGuard Home must default to disabled'
[[ -x "$init" ]] || fail 'AdGuard Home init script is not executable in the build overlay'

[[ ! -e "$PROJECT_ROOT/files/www/luci-static/resources/view/adguardhome/config.js" ]] || \
  fail 'project must not replace the manager with a simplified SPA page'

echo 'ADGUARD_MANAGER_PACKAGE_SOURCE=PINNED_FEED PASS'
echo 'ADGUARD_MANAGER_OVERLAY_SOURCE=PROJECT_CBI PASS'
echo 'ADGUARD_MANAGER_FEED_SOURCE_CHECK=PASS'
