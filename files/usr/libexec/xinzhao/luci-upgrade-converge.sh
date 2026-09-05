#!/bin/sh
set -eu

BUILD_INFO="${XINZHAO_BUILD_INFO:-/etc/xinzhao-build-info}"
STATE_DIR="${XINZHAO_STATE_DIR:-/etc/xinzhao-state}"
UCI="${XINZHAO_UCI:-uci}"
LOGGER="${XINZHAO_LOGGER:-logger}"
MARKER="$STATE_DIR/luci-migration-commit"

log() {
  "$LOGGER" -t xinzhaowrt "$*" 2>/dev/null || true
}

[ -r "$BUILD_INFO" ] || {
  log "LUCI_UPGRADE_CONVERGENCE_FAIL reason=build_info_missing"
  exit 1
}

commit="$(sed -n 's/^Git Commit:[[:space:]]*//p' "$BUILD_INFO" | head -n 1 | tr -d '\r')"
printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$' || {
  log "LUCI_UPGRADE_CONVERGENCE_FAIL reason=commit_invalid value=$commit"
  exit 1
}

previous=''
[ ! -r "$MARKER" ] || previous="$(tr -d '\r\n' < "$MARKER")"
if [ "$previous" = "$commit" ]; then
  log "LUCI_UPGRADE_CONVERGENCE_SKIP commit=$commit"
  exit 0
fi

# Preserved sysupgrade config can hide an older /etc/uci-defaults overlay or
# carry forward English/old-theme values.  Converge once for each firmware
# commit, then persist the commit marker so ordinary reboots do not overwrite
# later user choices.
"$UCI" -q get luci.main >/dev/null 2>&1 || "$UCI" -q set luci.main='core'
"$UCI" -q get luci.themes >/dev/null 2>&1 || "$UCI" -q set luci.themes='internal'
"$UCI" -q set luci.main.lang='zh_cn'
"$UCI" -q set luci.main.mediaurlbase='/luci-static/argon'
"$UCI" -q set luci.main.homepage='admin/quickstart'
"$UCI" -q set luci.themes.Argon='/luci-static/argon'
"$UCI" -q set luci.themes.KuCat='/luci-static/kucat'
"$UCI" -q commit luci

[ "$("$UCI" -q get luci.main.lang 2>/dev/null || true)" = 'zh_cn' ]
[ "$("$UCI" -q get luci.main.mediaurlbase 2>/dev/null || true)" = '/luci-static/argon' ]
[ "$("$UCI" -q get luci.main.homepage 2>/dev/null || true)" = 'admin/quickstart' ]
[ "$("$UCI" -q get luci.themes.Argon 2>/dev/null || true)" = '/luci-static/argon' ]
[ "$("$UCI" -q get luci.themes.KuCat 2>/dev/null || true)" = '/luci-static/kucat' ]

mkdir -p "$STATE_DIR"
tmp="$MARKER.tmp.$$"
printf '%s\n' "$commit" > "$tmp"
mv -f "$tmp" "$MARKER"
sync 2>/dev/null || true
log "LUCI_UPGRADE_CONVERGENCE_PASS commit=$commit lang=zh_cn theme=argon homepage=admin/quickstart"
exit 0
