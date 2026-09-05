#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FUNCTIONAL_ACCEPTANCE_GATE: FAIL -- $*" >&2; exit 1; }

build_env="$root/build.env"
wifi_defaults="$root/files/etc/uci-defaults/98-xinzhao-wifi-defaults"
firstboot_defaults="$root/files/etc/uci-defaults/99-xinzhao-defaults"
verify="$root/scripts/real-device-verify.ps1"

grep -Fxq 'DEFAULT_WIFI_SSID="xinzhaowrt"' "$build_env" || fail 'build.env must define the authoritative Wi-Fi SSID'
grep -Fxq 'DEFAULT_WIFI_PASSWORD="12345678"' "$build_env" || fail 'build.env must define the authoritative Wi-Fi password'
grep -Fxq 'DEFAULT_ROOT_PASSWORD="passwort"' "$build_env" || fail 'build.env must define the authoritative initial root password'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$wifi_defaults" || fail 'independent Wi-Fi defaults must use the authoritative SSID'
grep -Fq "wifi_default_password='12345678'" "$wifi_defaults" || fail 'independent Wi-Fi defaults must use the authoritative password'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$firstboot_defaults" || fail 'first-boot defaults must use the authoritative SSID'
grep -Fq "wifi_default_password='12345678'" "$firstboot_defaults" || fail 'first-boot defaults must use the authoritative password'
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)' "$wifi_defaults" || fail 'legacy band-specific SSIDs remain in independent defaults'
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)' "$firstboot_defaults" || fail 'legacy band-specific SSIDs remain in first-boot defaults'

package_root="${ADGUARD_MANAGER_PACKAGE_ROOT:-$root/work/immortalwrt/package/feeds/xinzhao/luci-app-adguardhome}"
if [[ -d "$package_root" ]]; then
  ADGUARD_MANAGER_PACKAGE_ROOT="$package_root" "$root/tests/test-adguard-manager.sh" || fail 'the prepared mature AdGuard manager contract failed'
else
  PYTHON_BIN="${PYTHON_BIN:-python3}" "$root/tests/test-adguard-source-of-truth.sh" || fail 'the pinned mature AdGuard source-of-truth contract failed'
fi

grep -Fq 'ARTHUR_LUCI_COOKIE_FILE' "$verify" || fail 'real-device verification must require an existing authenticated LuCI session'
! grep -Fq 'ARTHUR_ROOT_PASSWORD' "$verify" || fail 'real-device verification must not depend on or handle the root password after SSH bootstrap'
grep -Fq 'session access' "$verify" || fail 'real-device verification must exercise authenticated rpcd session access'
grep -Fq 'adguard_rpc_functional' "$verify" || fail 'real-device verification must include AdGuard RPC functionality'
grep -Fq 'adguard_page_functional' "$verify" || fail 'real-device verification must include authenticated AdGuard page functionality'
grep -Fq '/cgi-bin/luci/admin/quickstart' "$verify" || fail 'real-device verification must exercise the official QuickStart route'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device verification must assert the official QuickStart frontend is rendered'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device verification must include QuickStart homepage functionality'
grep -Fq 'prebuild_features' "$verify" || fail 'real-device verification must publish the prebuild feature gate evidence'
grep -Fq '33462873812' "$verify" || fail 'real-device verification must refuse the invalidated candidate'

echo 'FUNCTIONAL_ACCEPTANCE_GATE: PASS'
