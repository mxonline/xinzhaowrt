#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FUNCTIONAL_ACCEPTANCE: FAIL -- $*" >&2; exit 1; }

build_env="$root/build.env"
firstboot="$root/files/etc/uci-defaults/99-xinzhao-defaults"
verify="$root/scripts/real-device-verify.ps1"
verify_v3="$root/scripts/real-device-verify-v3.ps1"
resume="$root/production/resume-state.json"
python_bin="${PYTHON_BIN:-python3}"

grep -Fxq 'DEFAULT_ROOT_PASSWORD="password"' "$build_env" || fail 'authoritative root password must remain password'
grep -Fxq 'DEFAULT_WIFI_SSID="xinzhaowrt"' "$build_env" || fail 'authoritative Wi-Fi SSID must remain xinzhaowrt'
grep -Fxq 'DEFAULT_WIFI_PASSWORD="12345678"' "$build_env" || fail 'authoritative Wi-Fi password must remain 12345678'
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$firstboot" || fail 'first-boot Wi-Fi SSID is inconsistent'
grep -Fq "wifi_default_password='12345678'" "$firstboot" || fail 'first-boot Wi-Fi password is inconsistent'
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)|12356789' "$firstboot" || fail 'obsolete Wi-Fi defaults remain active'

PYTHON_BIN="$python_bin" bash "$root/tests/test-adguard-source-of-truth.sh" || fail 'mature AdGuard single-source contract failed'

"$python_bin" - "$resume" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding='utf-8'))
if state.get('verified', {}).get('wifi') != 'VERIFIED_FROZEN':
    raise SystemExit('current production resume state does not preserve VERIFIED_FROZEN Wi-Fi evidence')
PY

grep -Fq 'ensure-arthur-unattended-access.ps1' "$verify" || fail 'real-device verification must recover unattended SSH access'
grep -Fq 'New-LuciSessionFromSsh' "$verify" || fail 'real-device verification must create an authenticated LuCI session from verified SSH'
grep -Fq 'resume-state.json' "$verify" || fail 'prebuild Wi-Fi freeze must inherit current production resume-state evidence'
! grep -Fq 'wifi-frozen-baseline.json' "$verify" || fail 'verifier must not depend on the obsolete branch-specific Wi-Fi baseline file'
for marker in wifi_2g wifi_5g wifi_ssids wifi_password; do
  grep -Fq "$marker" "$verify" || fail "PostFlash verifier is missing read-only Wi-Fi check: $marker"
done

grep -Fq 'adguard_rpc_functional' "$verify" || fail 'real-device verification must include authenticated AdGuard RPC functionality'
grep -Fq 'adguard_page_functional' "$verify" || fail 'real-device verification must include authenticated AdGuard page functionality'
grep -Fq '/cgi-bin/luci/admin/quickstart/' "$verify" || fail 'real-device verification must exercise the official QuickStart route'
grep -Fq 'luci-static/quickstart/index.js' "$verify" || fail 'real-device verification must assert rendered QuickStart assets'
grep -Fq 'quickstart_home_functional' "$verify" || fail 'real-device verification must require functional QuickStart rendering'
grep -Fq 'prebuild_features' "$verify" || fail 'real-device verification must publish prebuild feature evidence'
grep -Fq 'FIRMWARE_BUILD_ALLOWED' "$verify" || fail 'real-device verification must publish the firmware build permission gate'
grep -Fq '33462873812' "$verify_v3" || fail 'invalidated pre-fix candidate must remain rejected'

echo 'FUNCTIONAL_ACCEPTANCE=PASS'
