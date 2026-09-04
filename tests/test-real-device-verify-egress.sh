#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$root/scripts/real-device-verify.ps1"

grep -Fq 'INET=ICMP_PASS' "$verifier" || { echo 'FAIL: real-device verifier must accept successful ICMP egress.' >&2; exit 1; }
grep -Fq 'INET=HTTPS_PASS' "$verifier" || { echo 'FAIL: real-device verifier must accept independent HTTPS egress when upstream filters ICMP.' >&2; exit 1; }
grep -Fq 'https://openwrt.org/' "$verifier" || { echo 'FAIL: HTTPS egress probe must use a stable non-IP endpoint.' >&2; exit 1; }
! grep -Fq "'ping -c 2 -W 3 1.1.1.1'" "$verifier" || { echo 'FAIL: ICMP must not be the sole internet acceptance requirement.' >&2; exit 1; }

echo 'REAL_DEVICE_EGRESS_CONTRACT=PASS'
