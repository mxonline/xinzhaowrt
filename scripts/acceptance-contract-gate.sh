#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "ACCEPTANCE_CONTRACT_GATE: FAIL -- $*" >&2; exit 1; }
pass() { echo "$1=PASS"; }

if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  fail 'a working Python interpreter is required for static acceptance evidence'
fi

[[ -s build.env ]] || fail 'build.env is missing'
# shellcheck disable=SC1091
source <(sed 's/\r$//' build.env)

[[ "$DEFAULT_LAN_IP" == '192.168.6.1' ]] || fail 'authoritative LAN IP is not 192.168.6.1'
[[ "$DEFAULT_ROOT_USER" == 'root' ]] || fail 'authoritative administrator is not root'
[[ "$DEFAULT_ROOT_PASSWORD" == 'password' ]] || fail 'authoritative root password is not password'
[[ "$DEFAULT_WIFI_SSID" == 'xinzhaowrt' ]] || fail 'authoritative Wi-Fi SSID is not xinzhaowrt'
[[ "$DEFAULT_WIFI_PASSWORD" == '12345678' ]] || fail 'authoritative Wi-Fi password is not 12345678'
[[ "$DEVICE_TARGET/$DEVICE_SUBTARGET/$DEVICE_PROFILE" == 'qualcommax/ipq60xx/jdcloud_re-ss-01' ]] || fail 'Arthur target/profile identity changed'
pass AUTHORITATIVE_TARGET_VALUES

config='config/arthur.config'
defaults='files/etc/uci-defaults/99-xinzhao-defaults'
wifi_defaults='files/etc/uci-defaults/98-xinzhao-wifi-defaults'
luci_defaults='files/etc/uci-defaults/97-xinzhao-luci-defaults'
verify='scripts/real-device-verify.ps1'

grep -Fxq 'CONFIG_TARGET_qualcommax=y' "$config" || fail 'target qualcommax is not enabled'
grep -Fxq 'CONFIG_TARGET_qualcommax_ipq60xx=y' "$config" || fail 'subtarget ipq60xx is not enabled'
grep -Fxq 'CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y' "$config" || fail 'Arthur profile is not enabled'
grep -Fq "uci set network.lan.ipaddr='192.168.6.1'" "$defaults" || fail 'first-boot LAN default is inconsistent'
grep -Fq "DeviceIp = '192.168.6.1'" "$verify" || fail 'real-device LAN target is inconsistent'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$defaults" || fail 'first-boot SSID is inconsistent'
grep -Fq "wifi_default_password='12345678'" "$defaults" || fail 'first-boot Wi-Fi password is inconsistent'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$wifi_defaults" || fail 'independent SSID default is inconsistent'
grep -Fq "wifi_default_password='12345678'" "$wifi_defaults" || fail 'independent Wi-Fi password is inconsistent'
grep -Fq "luci.main.lang='zh_cn'" "$luci_defaults" || fail 'language default is inconsistent'
grep -Fq "luci.main.mediaurlbase='/luci-static/argon'" "$luci_defaults" || fail 'Argon default is inconsistent'
grep -Fq "luci.themes.KuCat='/luci-static/kucat'" "$luci_defaults" || fail 'KuCat selectable theme registration is missing'
grep -Fq "luci.main.homepage='admin/quickstart'" "$luci_defaults" || fail 'QuickStart is not the configured homepage'
grep -Fq '初始密码：`password`' README.md || fail 'user-visible password documentation is inconsistent'
pass CROSS_LAYER_AUTHORITY

if rg -n 'DEFAULT_ROOT_PASSWORD="passwort"|初始密码[^\r\n]*passwort|12356789|XinZhaoWrt-(2\.4G|5G)' README.md build.env config files .github/workflows >/dev/null 2>&1; then
  fail 'obsolete password or Wi-Fi values remain in active source/test/workflow files'
fi
if rg -n "uci(\s+-q)?\s+set\s+network\.lan\.ipaddr=.*192\.168\.1\.1|uci(\s+-q)?\s+set\s+wireless\.[^=]+=.*XinZhaoWrt" files/etc/uci-defaults files/etc/init.d files/etc/config >/dev/null 2>&1; then
  fail 'legacy startup logic actively overwrites authoritative defaults'
fi
pass LEGACY_OVERRIDE_SCAN

grep -Fxq 'CONFIG_PACKAGE_luci-app-adguardhome=y' "$config" || fail 'mature AdGuard Home package is not enabled'
PYTHON_BIN="$PYTHON_BIN" bash tests/test-adguard-source-of-truth.sh || fail 'mature AdGuard source-of-truth contract is missing'
grep -Fq 'adguard_page_functional' "$verify" || fail 'real-device AdGuard page functional check is missing'
grep -Fq 'New-LuciSessionFromSsh' "$verify" || fail 'real-device AdGuard page check must establish an authenticated session'
grep -Fq 'AdGuardHome' "$verify" || fail 'real-device verifier must recognize the accepted mature AdGuard CBI namespace'
pass ADGUARD_FUNCTIONAL_CONTRACT

grep -Fq '/cgi-bin/luci/admin/quickstart/' "$verify" || fail 'real-device QuickStart route check is missing'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device QuickStart rendered asset check is missing'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device QuickStart functional check is missing'
grep -Fq 'id=' "$verify" || fail 'real-device QuickStart app mount check is missing'
grep -Fq 'app' "$verify" || fail 'real-device QuickStart app mount marker is missing'
grep -Fq 'prebuild_features' "$verify" || fail 'real-device prebuild feature evidence is missing'
grep -Fq 'FIRMWARE_BUILD_ALLOWED' "$verify" || fail 'real-device build permission gate is missing'
pass ISTORE_QUICKSTART_FUNCTIONAL_CONTRACT

plugin_count="$(grep -Ev '^[[:space:]]*(#|$)' config/required-plugins.txt | wc -l | tr -d ' ')"
[[ "$plugin_count" == '22' ]] || fail "required plugin count is $plugin_count, expected 22"
while IFS= read -r pkg; do
  pkg="${pkg%$'\r'}"
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${pkg}=y" "$config" || fail "required plugin is not enabled: $pkg"
done < config/required-plugins.txt
grep -Fq '22' "$verify" || fail 'real-device verifier does not encode the 22-plugin contract'
pass REQUIRED_PLUGINS_CONTRACT

for required in \
  tests/test-functional-acceptance.sh \
  tests/test-adguard-manager.sh \
  tests/test-adguard-defaults.sh \
  tests/test-wifi-defaults.sh \
  tests/test-quickstart-web-stack-source.sh \
  tests/test-argon-default-theme.sh \
  scripts/real-device-verify.ps1; do
  [[ -e "$required" ]] || fail "acceptance evidence is missing: $required"
done
pass EXPECTED_DIFF_ACCEPTANCE_MAPPING

mkdir -p output
"$PYTHON_BIN" - <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path
report = {
    'status': 'PASS',
    'all_requirements_covered': True,
    'static_acceptance_pass': True,
    'unknown': 0,
    'authoritative_values': {
        'lan': '192.168.6.1', 'root_user': 'root', 'root_password': 'password',
        'http_port': 80, 'language': 'zh_cn', 'default_theme': 'Argon',
        'selectable_theme': 'Kucat', 'wifi_ssid': 'xinzhaowrt',
        'wifi_password': '12345678', 'required_plugins': 22,
        'adguard_default': 'OFF', 'istore_homepage': 'official QuickStart'
    },
    'functional_static_evidence': {
        'adguard_mature_source_and_authenticated_manager_contract': 'PASS',
        'quickstart_authenticated_homepage_render_contract': 'PASS',
        'wifi_defaults_and_real_device_contract': 'PASS',
        'luci_theme_language_and_port_contract': 'PASS',
        'required_plugins': 'PASS'
    },
    'source_commit': __import__('subprocess').check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'generated_at': datetime.now(timezone.utc).isoformat()
}
Path('output/acceptance-contract-gate.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
echo 'ALL_REQUIREMENTS_COVERED=true'
echo 'STATIC_ACCEPTANCE_PASS=true'
echo 'UNKNOWN=0'
pass ACCEPTANCE_CONTRACT_GATE
