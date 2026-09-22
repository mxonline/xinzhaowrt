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

echo 'ZRAM_CLOSURE_SCRIPT_CONTRACT=PASS'
