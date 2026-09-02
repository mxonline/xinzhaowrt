#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/scripts/check-implementation-gates.sh"

[[ -f "$gate" ]] || { echo 'FAIL: implementation gate script is missing.' >&2; exit 1; }
grep -Fq 'origin/main' "$gate" || { echo 'FAIL: frozen baseline comparison is missing.' >&2; exit 1; }
grep -Fq 'V013_IMPLEMENTATION_GATES' "$gate" || { echo 'FAIL: implementation gate identity is missing.' >&2; exit 1; }
grep -Fq 'WIFI=VERIFIED_FROZEN' "$gate" || { echo 'FAIL: frozen Wi-Fi state is not explicit.' >&2; exit 1; }
grep -Fq 'ADGUARD_REAL_DEVICE=NOT_RUN' "$gate" || { echo 'FAIL: AdGuard real-device state must start NOT_RUN.' >&2; exit 1; }
grep -Fq 'QUICKSTART_REAL_DEVICE=NOT_RUN' "$gate" || { echo 'FAIL: QuickStart real-device state must start NOT_RUN.' >&2; exit 1; }
grep -Fq 'FIRMWARE_BUILD_ALLOWED=true' "$gate" || { echo 'FAIL: build permission must be gated by implementation checks.' >&2; exit 1; }
! grep -Fq 'V013_PREBUILD_REAL_DEVICE_FEATURES=PASS' "$gate" || { echo 'FAIL: implementation gate must not fabricate real-device PASS.' >&2; exit 1; }

echo 'PASS: implementation gate separates source acceptance from real-device verification.'
