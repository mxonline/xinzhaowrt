#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch="$root/patches/openclash/0013-core-version-probe-memory-guard.patch"

[ -s "$patch" ] || { echo 'FAIL: core version probe memory guard patch is missing' >&2; exit 1; }

grep -Fq 'MemAvailable:' "$patch" || { echo 'FAIL: core version probe has no MemAvailable guard' >&2; exit 1; }
grep -Fq 'Core version probe skipped below' "$patch" || { echo 'FAIL: low-memory probe must fail closed with an explicit log' >&2; exit 1; }
grep -Fq 'del_lock' "$patch" || { echo 'FAIL: low-memory probe guard must release the updater lock' >&2; exit 1; }
grep -Fq 'CORE_CV=' "$patch" || { echo 'FAIL: guard is not placed on the core version probe path' >&2; exit 1; }

echo 'PASS: OpenClash core version probe is guarded on low-memory Arthur'
