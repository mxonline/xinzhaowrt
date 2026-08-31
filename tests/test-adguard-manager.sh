#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
view="$root/files/www/luci-static/resources/view/adguardhome/config.js"
[[ -f "$view" ]] || { echo 'FAIL: AdGuard Home full manager view is missing.' >&2; exit 1; }
for label in '基础设置' '日志' '手动设置' '启动' '停止' '重启' '自动刷新' 'YAML' '备份' '恢复' '校验' '回滚'; do
  grep -Fq "$label" "$view" || { echo "FAIL: missing AdGuard manager label: $label" >&2; exit 1; }
done
grep -Fq "luci-i18n" "$view" || { echo 'FAIL: AdGuard manager must be translation-aware.' >&2; exit 1; }
grep -Fq "service.action" "$view" || { echo 'FAIL: service controls must use LuCI service RPC.' >&2; exit 1; }
echo 'PASS: AdGuard Home full manager static contract.'
