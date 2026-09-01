#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FUNCTIONAL_ACCEPTANCE_GATE: FAIL -- $*" >&2; exit 1; }

build_env="$root/build.env"
wifi_defaults="$root/files/etc/uci-defaults/98-xinzhao-wifi-defaults"
firstboot_defaults="$root/files/etc/uci-defaults/99-xinzhao-defaults"
verify="$root/scripts/real-device-verify.ps1"
acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"

grep -Fxq 'DEFAULT_WIFI_SSID="xinzhaowrt"' "$build_env" || fail 'build.env must define the authoritative Wi-Fi SSID'
grep -Fxq 'DEFAULT_WIFI_PASSWORD="12345678"' "$build_env" || fail 'build.env must define the authoritative Wi-Fi password'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$wifi_defaults" || fail 'independent Wi-Fi defaults must use the authoritative SSID'
grep -Fq "wifi_default_password='12345678'" "$wifi_defaults" || fail 'independent Wi-Fi defaults must use the authoritative password'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$firstboot_defaults" || fail 'first-boot defaults must use the authoritative SSID'
grep -Fq "wifi_default_password='12345678'" "$firstboot_defaults" || fail 'first-boot defaults must use the authoritative password'
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)' "$wifi_defaults" || fail 'legacy band-specific SSIDs remain in independent defaults'
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)' "$firstboot_defaults" || fail 'legacy band-specific SSIDs remain in first-boot defaults'

[[ -s "$acl" ]] || fail 'AdGuard Home RPC ACL is missing'
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fail 'Python 3 is required to validate the AdGuard rpcd ACL JSON'
fi
"$python_bin" - "$acl" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    acl = json.load(handle)["luci-app-adguardhome"]

assert "getInitList" in acl["read"]["ubus"]["luci"]
assert "status" in acl["read"]["ubus"]["network.interface.lan"]
assert "setInitAction" in acl["write"]["ubus"]["luci"]
assert "read" in acl["read"]["ubus"]["file"]
assert "write" in acl["write"]["ubus"]["file"]
read_files = acl["read"]["file"]
write_files = acl["write"]["file"]
assert "read" in read_files["/etc/adguardhome/adguardhome.yaml"]
assert "exec" in read_files["/usr/bin/AdGuardHome --version"]
assert "write" in write_files["/etc/adguardhome/adguardhome.yaml"]
assert "write" in write_files["/etc/adguardhome/adguardhome.yaml.xinzhao-backup"]
assert "exec" in write_files["/bin/cp *"]
PY

grep -Fq 'session access' "$verify" || fail 'real-device verification must exercise rpcd session access'
grep -Fq 'adguard_rpc_functional' "$verify" || fail 'real-device verification must include AdGuard RPC functionality'
grep -Fq '/cgi-bin/luci/admin/quickstart' "$verify" || fail 'real-device verification must exercise the official QuickStart route'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device verification must assert the official QuickStart frontend is rendered'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device verification must include QuickStart homepage functionality'
grep -Fq '33462873812' "$verify" || fail 'real-device verification must refuse the invalidated candidate'

echo 'FUNCTIONAL_ACCEPTANCE_GATE: PASS'
