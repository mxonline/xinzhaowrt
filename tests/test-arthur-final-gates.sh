#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-arthur-final-gates.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

HEAD="$(git -C "$ROOT" rev-parse HEAD)"
CLOSURE="$TMP/closure.txt"
LIVE="$TMP/live.txt"
OUT="$TMP/final.txt"

cat > "$CLOSURE" <<EOF
ZRAM_CONFIG_INCLUDED=PASS
KMOD_ZRAM_COMPILE=PASS
ZRAM_SWAP_PACKAGE_COMPILE=PASS
KERNEL_DEPENDENCY_CLOSURE=PASS
TARGET=qualcommax/ipq60xx
PROFILE=jdcloud_re-ss-01
FIRMWARE_BUILD_COUNT_NEW=0
SOURCE_SHA=$HEAD
EOF

cat > "$LIVE" <<EOF
REAL_DEVICE_FULL_VALIDATION=PASS
FINAL_SOURCE_SHA=$HEAD
FIRMWARE_BUILD_COUNT_NEW=0
EOF

[[ -s "$GATE" ]] || fail 'final gate script is missing'

cp "$LIVE" "$TMP/stale-live.txt"
sed -i 's/^FINAL_SOURCE_SHA=.*/FINAL_SOURCE_SHA=0000000000000000000000000000000000000000/' "$TMP/stale-live.txt"
if bash "$GATE" --closure "$CLOSURE" --live "$TMP/stale-live.txt" --output "$OUT" > "$TMP/stale.out" 2>&1; then
  fail 'stale live evidence was accepted'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/stale.out" || fail 'stale-source failure did not fail closed'

bash "$GATE" --closure "$CLOSURE" --live "$LIVE" --output "$OUT" > "$TMP/pass.out"
for marker in \
  ZRAM_CONFIG_INCLUDED=PASS \
  KMOD_ZRAM_COMPILE=PASS \
  ZRAM_SWAP_PACKAGE_COMPILE=PASS \
  KERNEL_DEPENDENCY_CLOSURE=PASS \
  REAL_DEVICE_FULL_VALIDATION=PASS \
  FINAL_SOURCE_FROZEN=PASS \
  EXACT_SOURCE_BINDING=PASS \
  FIRMWARE_BUILD_COUNT_NEW=0 \
  BUILD_ALLOWED=true; do
  grep -Fqx "$marker" "$OUT" || fail "final gate output is missing $marker"
done
grep -Fqx "FINAL_SOURCE_SHA=$HEAD" "$OUT" || fail 'final source SHA is not exact HEAD'
grep -Fq 'check-arthur-final-gates.sh' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not invoke the final gate'
grep -Fq 'BUILD_ALLOWED=true' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not require BUILD_ALLOWED=true'

echo 'ARTHUR_FINAL_GATES_TEST=PASS'
