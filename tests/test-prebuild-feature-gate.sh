#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/scripts/check-prebuild-real-device-gate.sh"
verify="$root/scripts/real-device-verify.ps1"
access="$root/scripts/ensure-arthur-unattended-access.ps1"
policy="$root/production/arthur-control-plane.json"
wifi_baseline="$root/production/wifi-frozen-baseline.json"

[[ -x "$gate" || -f "$gate" ]] || { echo 'FAIL: prebuild real-device gate script is missing.' >&2; exit 1; }
grep -Fq 'ADGUARD_LIVE' "$gate" || { echo 'FAIL: prebuild gate must require ADGUARD_LIVE.' >&2; exit 1; }
grep -Fq 'QUICKSTART_LIVE' "$gate" || { echo 'FAIL: prebuild gate must require QUICKSTART_LIVE.' >&2; exit 1; }
grep -Fq 'FIRMWARE_BUILD_ALLOWED' "$gate" || { echo 'FAIL: prebuild gate must control build permission.' >&2; exit 1; }
grep -Fq 'WIFI_STATE' "$gate" || { echo 'FAIL: prebuild gate must consume frozen Wi-Fi state instead of requiring a fresh WIFI_LIVE run.' >&2; exit 1; }
grep -Fq 'VERIFIED_FROZEN' "$gate" || { echo 'FAIL: prebuild gate must require WIFI_STATE=VERIFIED_FROZEN.' >&2; exit 1; }
! grep -Fq 'features.get("WIFI_LIVE") == "PASS"' "$gate" || { echo 'FAIL: prebuild gate must not require a fresh WIFI_LIVE PASS for frozen Wi-Fi.' >&2; exit 1; }

grep -Fq 'Ensure-ArthurUnattendedAccess' "$verify" || { echo 'FAIL: verifier must recover the Arthur control plane before SSH checks.' >&2; exit 1; }
grep -Fq 'New-LuciSessionFromSsh' "$verify" || { echo 'FAIL: verifier must be able to create an authenticated LuCI session from verified root SSH without an operator cookie.' >&2; exit 1; }
! grep -Fq 'No existing authenticated LuCI cookie was supplied' "$verify" || { echo 'FAIL: verifier must not stop merely because an operator did not supply a cookie.' >&2; exit 1; }
grep -Fq 'WIFI_STATE' "$verify" || { echo 'FAIL: verifier must emit durable frozen Wi-Fi state.' >&2; exit 1; }
grep -Fq 'VERIFIED_FROZEN' "$verify" || { echo 'FAIL: verifier must inherit the accepted Wi-Fi baseline.' >&2; exit 1; }
! grep -Fq 'Get-WifiConfigurationSnapshot' "$verify" || { echo 'FAIL: prebuild verifier must not re-run Wi-Fi configuration verification for frozen Wi-Fi.' >&2; exit 1; }

[[ -f "$access" ]] || { echo 'FAIL: unattended Arthur access recovery helper is missing.' >&2; exit 1; }
[[ -f "$policy" ]] || { echo 'FAIL: Arthur control-plane identity policy is missing.' >&2; exit 1; }
[[ -f "$wifi_baseline" ]] || { echo 'FAIL: frozen Wi-Fi source baseline is missing.' >&2; exit 1; }
grep -Fq 'dc:d8:7c:46:91:24' "$policy" || { echo 'FAIL: control-plane policy must pin the already verified Arthur management MAC.' >&2; exit 1; }
grep -Fq -- "-StrictMode 'accept-new'" "$access" || { echo 'FAIL: host-key recovery must capture a candidate key in an isolated accept-new trust store.' >&2; exit 1; }
grep -Fq 'Get-NetNeighbor' "$access" || { echo 'FAIL: host-key recovery must bind the endpoint to the verified Ethernet neighbor MAC.' >&2; exit 1; }
grep -Fq 'ubus call system board' "$access" || { echo 'FAIL: host-key recovery must authenticate and verify the Arthur board before trust replacement.' >&2; exit 1; }
grep -Fq 'build-info.json' "$access" || { echo 'FAIL: host-key recovery must authenticate and verify XinZhaoWrt build identity before trust replacement.' >&2; exit 1; }
grep -Fq 'known_hosts' "$access" || { echo 'FAIL: host-key recovery must use a durable known_hosts trust store.' >&2; exit 1; }
grep -Fqi 'backup' "$access" || { echo 'FAIL: known_hosts mutation must be backed up before replacement.' >&2; exit 1; }
! grep -Fq 'StrictHostKeyChecking=no' "$access" || { echo 'FAIL: unattended recovery may never disable host-key verification.' >&2; exit 1; }
! grep -Eq 'ssh-keygen(\.exe)?[[:space:]]+-R[[:space:]]+[^#]*192\.168\.6\.1' "$access" || { echo 'FAIL: host-key recovery may not blindly delete trust for 192.168.6.1.' >&2; exit 1; }

grep -Fq '4358685989bf9f0207fb6717dc63dd89a295f27e' "$wifi_baseline" || { echo 'FAIL: frozen Wi-Fi baseline must pin the accepted source blob.' >&2; exit 1; }

grep -Fq 'PREBUILD_REAL_DEVICE_GATE_FAILED' 'scripts/github-app-auth.ps1' || { echo 'FAIL: production dispatch must remain blocked by the prebuild gate.' >&2; exit 1; }
grep -Fq 'prebuild_features' "$verify" || { echo 'FAIL: real-device verifier must emit prebuild feature evidence.' >&2; exit 1; }
grep -Fq 'LuciCookieFile' 'scripts/real-device-verify-v3.ps1' || { echo 'FAIL: v3 verifier wrapper must preserve optional LuCI cookie compatibility.' >&2; exit 1; }
grep -Fq '#HttpOnly_' "$verify" || { echo 'FAIL: verifier must parse curl Netscape cookie jars with HttpOnly session cookies.' >&2; exit 1; }
grep -Fq 'provided-cookie' "$verify" || { echo 'FAIL: verifier must preserve a supplied authenticated LuCI cookie.' >&2; exit 1; }
grep -Fq '/cgi-bin/luci/admin/services/AdGuardHome/overview' "$verify" || { echo 'FAIL: verifier must accept the deployed uppercase AdGuard Home CBI manager routes.' >&2; exit 1; }

echo 'PASS: prebuild gate supports unattended Arthur access recovery and inherits the frozen Wi-Fi baseline.'
