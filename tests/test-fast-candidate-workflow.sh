#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/arthur-fast-candidate.yml"

fail() {
  echo "ARTHUR_FAST_CANDIDATE_WORKFLOW: FAIL -- $*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail 'SDK/ImageBuilder candidate workflow is missing'
grep -Fq 'immortalwrt-sdk-qualcommax-ipq60xx_gcc-14.4.0_musl.Linux-x86_64.tar.zst' "$workflow" || fail 'matching SDK bundle is not required'
grep -Fq 'immortalwrt-imagebuilder-qualcommax-ipq60xx.Linux-x86_64.tar.zst' "$workflow" || fail 'matching ImageBuilder bundle is not required'
grep -Fq 'package-repositories.tar.gz' "$workflow" || fail 'verified package repository is not required'
grep -Fq -- '--pattern build-info.txt' "$workflow" || fail 'build-info must be downloaded before validating every toolchain checksum'
grep -Fq 'package/feeds/xinzhao/quickstart/compile V=s' "$workflow" || fail 'QuickStart-only SDK build is missing'
grep -Fq 'image PROFILE=jdcloud_re-ss-01' "$workflow" || fail 'Arthur ImageBuilder assembly is missing'
grep -Fq './scripts/check-defaults.sh' "$workflow" || fail 'first-boot static gate is missing'
grep -Fq './scripts/check-web-stack.sh' "$workflow" || fail 'web-stack static gate is missing'
grep -Fq 'WEB_STACK_GATE' "$workflow" || fail 'runtime web-stack gate output is missing'
grep -Fq 'serve --unix /tmp/quickstart.sock' "$workflow" || fail 'QuickStart service execution probe is missing'
grep -Fq 'test "$quickstart_exit" -ne 127' "$workflow" || fail 'QuickStart service probe does not reject procd-style exit 127'
grep -Fq 'image-files/etc/uci-defaults/98-xinzhao-web-stack' "$workflow" || fail 'runtime web-stack gate does not inspect the nginx/uhttpd overlay'
grep -Fq "grep -Fq '/etc/init.d/nginx restart' image-files/etc/uci-defaults/98-xinzhao-web-stack" "$workflow" || fail 'runtime web-stack gate does not validate the nginx restart action'
! grep -Eq '(^|[[:space:]])\./scripts/build\.sh|make world|FULL_BUILD' "$workflow" || fail 'workflow contains a prohibited full build'

echo 'ARTHUR_FAST_CANDIDATE_WORKFLOW: PASS'
