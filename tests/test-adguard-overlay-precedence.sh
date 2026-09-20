#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_feed_source() {
  local src="$1"
  mkdir -p \
    "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/luci/menu.d" \
    "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/rpcd/acl.d" \
    "$src/package/feeds/xinzhao/luci-app-adguardhome/htdocs/luci-static/resources/view/adguardhome"
  cat > "$src/package/feeds/xinzhao/luci-app-adguardhome/Makefile" <<'EOF'
LUCI_DEPENDS:=+adguardhome +luci-base
EOF
  cat > "$src/package/feeds/xinzhao/luci-app-adguardhome/htdocs/luci-static/resources/view/adguardhome/config.js" <<'EOF'
return view.extend({ render: function() { return E('div', {}, _('Basic upstream configuration view')); } });
EOF
  cat > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/luci/menu.d/luci-app-adguardhome.json" <<'EOF'
{"admin/services/adguardhome":{"action":{"type":"view","path":"adguardhome/config"}}}
EOF
  cat > "$src/package/feeds/xinzhao/luci-app-adguardhome/root/usr/share/rpcd/acl.d/luci-app-adguardhome.json" <<'EOF'
{"luci-app-adguardhome":{"read":{"uci":["adguardhome"]}}}
EOF
}

make_project_manager() {
  local src="$1"
  mkdir -p \
    "$src/files/usr/share/luci/menu.d" \
    "$src/files/usr/share/rpcd/acl.d" \
    "$src/files/usr/lib/lua/luci/controller" \
    "$src/files/usr/lib/lua/luci/view/AdGuardHome" \
    "$src/files/etc/config" \
    "$src/files/etc/init.d"
  cat > "$src/files/usr/share/luci/menu.d/luci-app-adguardhome.json" <<'EOF'
{"admin/services/AdGuardHome":{"action":{"type":"alias","path":"admin/services/AdGuardHome/overview"}},"admin/services/AdGuardHome/overview":{"action":{"type":"cbi","path":"AdGuardHome/overview"}},"admin/services/AdGuardHome/base":{"action":{"type":"cbi","path":"AdGuardHome/base"}},"admin/services/AdGuardHome/tools":{"action":{"type":"cbi","path":"AdGuardHome/tools"}},"admin/services/AdGuardHome/log":{"action":{"type":"form","path":"AdGuardHome/log"}},"admin/services/AdGuardHome/manual":{"action":{"type":"cbi","path":"AdGuardHome/manual"}}}
EOF
  cat > "$src/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json" <<'EOF'
{"luci-app-adguardhome":{"read":{"ubus":{"luci":["getInitList"]},"uci":["AdGuardHome"]},"write":{"ubus":{"luci":["setInitAction"]},"uci":["AdGuardHome"]}}}
EOF
  cat > "$src/files/usr/lib/lua/luci/controller/AdGuardHome.lua" <<'EOF'
function service_action() end
local SERVICE_ACTIONS = { start = "start", stop = "stop", restart = "restart", enable = "enable", disable = "disable" }
EOF
  for action in start stop restart enable disable; do
    printf 'data-adg-action="%s"\n' "$action" >> "$src/files/usr/lib/lua/luci/view/AdGuardHome/overview.htm"
  done
  printf '%s\n' "config AdGuardHome 'AdGuardHome'" " option enabled '0'" > "$src/files/etc/config/AdGuardHome"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$src/files/etc/init.d/AdGuardHome"
  chmod 0755 "$src/files/etc/init.d/AdGuardHome"
}

good="$tmp/good"
make_feed_source "$good"
make_project_manager "$good"
menu_before="$(sha256sum "$good/files/usr/share/luci/menu.d/luci-app-adguardhome.json" | awk '{print $1}')"
acl_before="$(sha256sum "$good/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json" | awk '{print $1}')"

bash "$root/scripts/restore-pinned-adguard-manager.sh" "$good"

menu_after="$(sha256sum "$good/files/usr/share/luci/menu.d/luci-app-adguardhome.json" | awk '{print $1}')"
acl_after="$(sha256sum "$good/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json" | awk '{print $1}')"
[[ "$menu_before" == "$menu_after" ]] || { echo 'FAIL: project CBI menu was replaced by the feed SPA menu.' >&2; exit 1; }
[[ "$acl_before" == "$acl_after" ]] || { echo 'FAIL: project lifecycle ACL was replaced by the feed ACL.' >&2; exit 1; }
grep -Fq 'AdGuardHome/overview' "$good/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
grep -Fq 'setInitAction' "$good/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

bad="$tmp/bad"
make_feed_source "$bad"
mkdir -p "$bad/files/usr/share/luci/menu.d" "$bad/files/usr/share/rpcd/acl.d"
printf '%s\n' '{"admin/services/adguardhome":{"action":{"type":"view","path":"adguardhome/config"}}}' > "$bad/files/usr/share/luci/menu.d/luci-app-adguardhome.json"
printf '%s\n' '{"luci-app-adguardhome":{"read":{"uci":["adguardhome"]}}}' > "$bad/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

if bash "$root/scripts/restore-pinned-adguard-manager.sh" "$bad" >/dev/null 2>&1; then
  echo 'FAIL: build accepted the upstream basic page as a substitute for the full manager.' >&2
  exit 1
fi
grep -Fq 'admin/services/adguardhome' "$bad/files/usr/share/luci/menu.d/luci-app-adguardhome.json"

echo 'ADGUARD_OVERLAY_PRECEDENCE=PASS'
