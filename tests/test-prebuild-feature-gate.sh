#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/scripts/check-prebuild-real-device-gate.sh"
verify="$root/scripts/real-device-verify.ps1"

[[ -x "$gate" || -f "$gate" ]] || { echo 'FAIL: prebuild real-device gate script is missing.' >&2; exit 1; }
grep -Fq 'ADGUARD_LIVE' "$gate" || { echo 'FAIL: prebuild gate must require ADGUARD_LIVE.' >&2; exit 1; }
grep -Fq 'QUICKSTART_LIVE' "$gate" || { echo 'FAIL: prebuild gate must require QUICKSTART_LIVE.' >&2; exit 1; }
grep -Fq 'WIFI_LIVE' "$gate" || { echo 'FAIL: prebuild gate must require WIFI_LIVE.' >&2; exit 1; }
grep -Fq 'FIRMWARE_BUILD_ALLOWED' "$gate" || { echo 'FAIL: prebuild gate must control build permission.' >&2; exit 1; }
grep -Fq 'wifi_configuration_mutated' "$gate" || { echo 'FAIL: prebuild gate must assert Wi-Fi was not mutated.' >&2; exit 1; }
grep -Fq 'Get-WifiConfigurationSnapshot' "$verify" || { echo 'FAIL: verifier must capture Wi-Fi configuration snapshots.' >&2; exit 1; }
! grep -Fq 'wifi_configuration_mutated = $false' "$verify" || { echo 'FAIL: Wi-Fi mutation evidence must not be hardcoded.' >&2; exit 1; }
grep -Fq 'wifi_configuration.unchanged' "$verify" || { echo 'FAIL: verifier must fail when Wi-Fi snapshots are missing or changed.' >&2; exit 1; }
grep -Fq 'PREBUILD_REAL_DEVICE_GATE_FAILED' 'scripts/github-app-auth.ps1' || { echo 'FAIL: production dispatch must be blocked by the prebuild gate.' >&2; exit 1; }
grep -Fq 'prebuild_features' "$verify" || { echo 'FAIL: real-device verifier must emit prebuild feature evidence.' >&2; exit 1; }
grep -Fq 'LuciCookieFile' 'scripts/real-device-verify-v3.ps1' || { echo 'FAIL: v3 verifier wrapper must pass the authenticated LuCI cookie.' >&2; exit 1; }
! grep -Fq 'RootPassword' 'scripts/real-device-verify-v3.ps1' || { echo 'FAIL: v3 verifier wrapper must not pass the removed password bootstrap parameter.' >&2; exit 1; }

echo 'PASS: prebuild real-device gate is fail-closed for both pages and preserves Wi-Fi evidence.'
