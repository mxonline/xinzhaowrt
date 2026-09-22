#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/zram-closure.sh"
WORKFLOW="$ROOT/.github/workflows/arthur-zram-closure.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -s "$SCRIPT" ]] || fail 'closure script is missing'
[[ -s "$WORKFLOW" ]] || fail 'GitHub closure workflow is missing'

for marker in \
  ZRAM_CONFIG_INCLUDED=PASS \
  KMOD_ZRAM_COMPILE=PASS \
  ZRAM_SWAP_PACKAGE_COMPILE=PASS \
  KERNEL_DEPENDENCY_CLOSURE=PASS \
  TARGET=qualcommax/ipq60xx \
  PROFILE=jdcloud_re-ss-01 \
  FIRMWARE_BUILD_COUNT_NEW=0; do
  grep -Fq "$marker" "$SCRIPT" || fail "closure script does not emit $marker"
done

for target in \
  'defconfig' \
  'target/linux/prepare' \
  'target/linux/compile' \
  'package/kernel/linux/compile' \
  'package/system/zram-swap/compile'; do
  grep -Fq "$target" "$SCRIPT" || fail "closure script is missing make target $target"
done

if rg -n '(^|[[:space:]])make[[:space:]]+(-[^[:space:]]+[[:space:]]+)*world([[:space:]]|$)' "$SCRIPT" "$WORKFLOW"; then
  fail 'closure path contains a make world invocation'
fi
if rg -n 'build\.sh|release-candidate|publish_github|sysupgrade\.bin|factory\.bin' "$SCRIPT" "$WORKFLOW"; then
  fail 'closure path contains a firmware/release action'
fi

grep -Fq 'runs-on: ubuntu-24.04' "$WORKFLOW" || fail 'closure must run on GitHub-hosted Linux'
grep -Fq 'scripts/zram-closure.sh' "$WORKFLOW" || fail 'workflow does not invoke the closure script'
grep -Fq 'LZ4_ARTIFACT=' "$SCRIPT" || fail 'closure does not verify the LZ4 kernel dependency artifact'
grep -Fq -- "-name 'kmod-zram-*.apk'" "$SCRIPT" || fail 'closure does not match actual kmod-zram APK names'
grep -Fq -- "-name 'kmod-lib-lz4-*.apk'" "$SCRIPT" || fail 'closure does not match actual kmod-lib-lz4 APK names'
grep -Fq -- "-name 'zram-swap-*.apk'" "$SCRIPT" || fail 'closure does not match actual zram-swap APK names'
grep -Fq -- "-path '*/packages/ipkg-*/kmod-zram/lib/modules/*/zram.ko'" "$SCRIPT" || fail 'closure does not accept the packaged zram.ko output path'
grep -Fq 'CONTROL_ONLY=true' "$WORKFLOW" || fail 'workflow does not mark the run control-only'
grep -Fq 'RUNTIME_BEHAVIOR_CHANGED=false' "$WORKFLOW" || fail 'workflow does not declare runtime behavior unchanged'
grep -Fq 'REAL_DEVICE_EVIDENCE_REUSE_ALLOWED=true' "$WORKFLOW" || fail 'workflow does not allow reuse of real-device evidence'

echo 'ZRAM_CLOSURE_SCRIPT_CONTRACT=PASS'
