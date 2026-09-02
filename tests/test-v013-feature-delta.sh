#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "V013_FEATURE_DELTA: FAIL -- $*" >&2; exit 1; }

acl="$root/files/usr/share/rpcd/acl.d/luci-app-adguardhome.json"
view="$root/files/www/luci-static/resources/view/adguardhome/config.js"
luci_defaults="$root/files/etc/uci-defaults/97-xinzhao-luci-defaults"
wifi_defaults="$root/files/etc/uci-defaults/99-xinzhao-defaults"
build_env="$root/build.env"

[[ -s "$acl" ]] || fail 'AdGuard Home rpcd ACL is missing'
[[ -s "$view" ]] || fail 'AdGuard Home LuCI manager is missing'
grep -Fq 'getInitList' "$acl" || fail 'AdGuard status permission missing'
grep -Fq 'setInitAction' "$acl" || fail 'AdGuard lifecycle permission missing'
grep -Fq 'adguardhome.yaml' "$acl" || fail 'AdGuard YAML permission missing'
grep -Fq "method: 'getInitList'" "$view" || fail 'AdGuard manager does not use LuCI init status RPC'
grep -Fq "method: 'setInitAction'" "$view" || fail 'AdGuard manager does not use LuCI init action RPC'
! grep -Fq "method: 'action'" "$view" || fail 'Legacy service.action RPC remains in AdGuard manager'
grep -Fq "homepage='admin/quickstart'" "$luci_defaults" || fail 'iStore QuickStart is not the LuCI homepage'
grep -Fq "DEFAULT_WIFI_SSID=\"xinzhaowrt\"" "$build_env" || fail 'build.env does not lock the requested Wi-Fi SSID'
grep -Fq "DEFAULT_WIFI_PASSWORD=\"12345678\"" "$build_env" || fail 'build.env does not lock the requested Wi-Fi password'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$wifi_defaults" || fail 'firstboot Wi-Fi SSID is not xinzhaowrt'
grep -Fq "wifi_default_password='12345678'" "$wifi_defaults" || fail 'firstboot Wi-Fi password is not locked'
grep -Fq 'wireless.$wifi_section.ssid=$wifi_default_ssid' "$wifi_defaults" || fail 'both Wi-Fi bands do not inherit the unified SSID'
! grep -Eq '/etc/init\.d/adguardhome[[:space:]]+enable|service[[:space:]]+adguardhome[[:space:]]+enable' "$root/files/etc/uci-defaults"/* 2>/dev/null || fail 'AdGuard Home must remain disabled by default'

echo 'V013_FEATURE_DELTA=PASS'
