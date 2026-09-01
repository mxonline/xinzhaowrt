#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FUNCTIONAL_ACCEPTANCE: FAIL -- $*" >&2; exit 1; }

acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
view="$root/files/www/luci-static/resources/view/adguardhome/config.js"
luci_defaults="$root/files/etc/uci-defaults/97-xinzhao-luci-defaults"
verify="$root/scripts/real-device-verify.ps1"

[[ -s "$acl" ]] || fail 'AdGuard Home rpcd ACL is missing'
[[ -s "$view" ]] || fail 'AdGuard Home full LuCI manager view is missing'

grep -Fq 'getInitList' "$acl" || fail 'AdGuard status RPC permission is missing'
grep -Fq 'setInitAction' "$acl" || fail 'AdGuard lifecycle RPC permission is missing'
grep -Fq 'adguardhome.yaml' "$acl" || fail 'AdGuard config read/write permission is missing'
grep -Fq '/usr/bin/AdGuardHome --version' "$acl" || fail 'AdGuard core exec permission is missing'

grep -Fq 'getInitList' "$view" || fail 'AdGuard manager does not read service status through LuCI RPC'
grep -Fq 'setInitAction' "$view" || fail 'AdGuard manager does not control service lifecycle through LuCI RPC'
grep -Fq 'fs.read(configPath)' "$view" || fail 'AdGuard manager cannot read YAML configuration'
grep -Fq 'fs.write(configPath' "$view" || fail 'AdGuard manager cannot save YAML configuration'
grep -Fq 'YAML 校验' "$view" || fail 'AdGuard manager lacks YAML validation'
grep -Fq '备份' "$view" || fail 'AdGuard manager lacks backup control'
grep -Fq '恢复' "$view" || fail 'AdGuard manager lacks restore control'
grep -Fq '日志' "$view" || fail 'AdGuard manager lacks log management'
grep -Fq '打开 AdGuard Home Web' "$view" || fail 'AdGuard manager lacks Web UI entry'

grep -Fq "homepage='admin/quickstart'" "$luci_defaults" || fail 'LuCI default homepage is not iStore QuickStart'
grep -Fq '/cgi-bin/luci/admin/quickstart' "$verify" || fail 'real-device verifier does not exercise the iStore QuickStart homepage route'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device verifier does not require rendered QuickStart frontend assets'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device verifier does not require functional QuickStart homepage rendering'
grep -Fq 'adguard_rpc_functional' "$verify" || fail 'real-device verifier does not require authenticated AdGuard management access'

echo 'FUNCTIONAL_ACCEPTANCE=PASS'
