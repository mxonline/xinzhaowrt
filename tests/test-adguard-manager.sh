#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
view="$root/files/www/luci-static/resources/view/adguardhome/config.js"
[[ -f "$view" ]] || { echo 'FAIL: AdGuard Home full manager view is missing.' >&2; exit 1; }
for label in '基础设置' '日志' '手动设置' '启动' '停止' '重启' '自动刷新' 'YAML' '备份' '恢复' '校验' '回滚'; do
  grep -Fq "$label" "$view" || { echo "FAIL: missing AdGuard manager label: $label" >&2; exit 1; }
done
grep -Fq "luci-i18n" "$view" || { echo 'FAIL: AdGuard manager must be translation-aware.' >&2; exit 1; }
grep -Fq "getInitList" "$view" || { echo 'FAIL: service status must use luci.getInitList.' >&2; exit 1; }
grep -Fq "setInitAction" "$view" || { echo 'FAIL: service controls must use luci.setInitAction.' >&2; exit 1; }
! grep -Fq "service.action" "$view" || { echo 'FAIL: obsolete service.action RPC remains.' >&2; exit 1; }
acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
[[ -s "$acl" ]] || { echo 'FAIL: AdGuard Home rpcd ACL is missing.' >&2; exit 1; }
grep -Fq 'getInitList' "$acl" || { echo 'FAIL: ACL does not grant status RPC.' >&2; exit 1; }
grep -Fq 'setInitAction' "$acl" || { echo 'FAIL: ACL does not grant lifecycle RPC.' >&2; exit 1; }
grep -Fq 'adguardhome.yaml' "$acl" || { echo 'FAIL: ACL does not grant AdGuard config access.' >&2; exit 1; }
echo 'PASS: AdGuard Home full manager static contract.'
