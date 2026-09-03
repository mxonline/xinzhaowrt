#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report="${1:-$root/output/real-device/real-device-verification.json}"
expected_commit="${2:-}"

[[ -s "$report" ]] || { echo "PREBUILD_REAL_DEVICE_GATE: FAIL -- missing evidence: $report" >&2; exit 1; }

if command -v python3 >/dev/null 2>&1; then
    python_bin=python3
elif command -v python >/dev/null 2>&1; then
    python_bin=python
else
    echo 'PREBUILD_REAL_DEVICE_GATE: FAIL -- Python 3 is required to parse durable evidence.' >&2
    exit 1
fi

"$python_bin" - "$report" "$expected_commit" <<'PY'
import json
import sys

path = sys.argv[1]
expected_commit = sys.argv[2] if len(sys.argv) > 2 else ""
with open(path, encoding="utf-8-sig") as handle:
    data = json.load(handle)

errors = []
features = data.get("prebuild_features") or {}
wifi = data.get("wifi_state") or {}
control = data.get("control_plane") or {}

def require(value, message):
    if not value:
        errors.append(message)

require(str(data.get("result", "")).upper() == "PASS", "real-device verification result is not PASS")
require(str(data.get("mode", "")).upper() == "PREBUILD", "evidence is not from non-disruptive Prebuild mode")
if expected_commit:
    require(data.get("commit") == expected_commit, "prebuild evidence commit does not match current source HEAD")
require(control.get("passed") is True, "unattended Arthur control-plane recovery is not PASS")
require(features.get("ADGUARD_LIVE") == "PASS", "ADGUARD_LIVE is not PASS")
require(features.get("QUICKSTART_LIVE") == "PASS", "QUICKSTART_LIVE is not PASS")
require(features.get("WIFI_STATE") == "VERIFIED_FROZEN", "WIFI_STATE is not VERIFIED_FROZEN")
require(features.get("FIRMWARE_BUILD_ALLOWED") == "true", "FIRMWARE_BUILD_ALLOWED is not true")
require(features.get("wifi_configuration_mutated") is False, "Wi-Fi configuration mutation marker is not false")
require(wifi.get("status") == "VERIFIED_FROZEN", "durable Wi-Fi baseline is not VERIFIED_FROZEN")
require(wifi.get("runtime_mutation_performed") is False, "prebuild mutated runtime Wi-Fi")
require(wifi.get("runtime_revalidation_performed") is False, "prebuild unexpectedly revalidated runtime Wi-Fi")
require((data.get("device") or {}).get("address") == "192.168.6.1", "device address mismatch")
require((data.get("device") or {}).get("target") == "jdcloud_re-ss-01", "device target mismatch")
require(len(data.get("failures") or []) == 0, "real-device failures are present")

if errors:
    print("PREBUILD_REAL_DEVICE_GATE: FAIL")
    for error in errors:
        print(f"- {error}")
    raise SystemExit(1)

print("PREBUILD_REAL_DEVICE_GATE: PASS")
print("WIFI_STATE=VERIFIED_FROZEN")
print("PREBUILD_MODE=NON_DISRUPTIVE")
if expected_commit:
    print(f"PREBUILD_SOURCE_SHA={expected_commit}")
PY
