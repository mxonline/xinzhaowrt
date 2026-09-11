#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy_path="work/$(printf '%s' immortalwrt)"
workflow="$root/.github/workflows/build.yml"

fail() {
  echo "PREFLIGHT_PATH_CONTRACT: FAIL -- $*" >&2
  exit 1
}

[[ -s "$workflow" ]] || fail "build workflow is missing: $workflow"
grep -Fq 'FEED_CHECK_ROOT: ${{ github.workspace }}/work/feed-check/immortalwrt' "$workflow" || \
  fail 'build preflight does not export the canonical FEED_CHECK_ROOT'

if rg -n -F "$legacy_path" "$root/scripts" "$root/tests" >/tmp/preflight-legacy-path-references.txt 2>/dev/null; then
  cat /tmp/preflight-legacy-path-references.txt >&2
  fail 'executable scripts/tests still reference the legacy checkout root'
fi

preflight_block="$(awk '
  /- name: Preflight project validation/ { in_block=1 }
  in_block { print }
  /- name: Build firmware/ { exit }
' "$workflow")"
grep -Fq 'FEED_CHECK_ROOT' <<<"$preflight_block" || fail 'Preflight block does not consume FEED_CHECK_ROOT'
! grep -Fq "$legacy_path" <<<"$preflight_block" || fail 'Preflight block references legacy checkout root'

for script in \
  tests/test-adguard-manager.sh \
  tests/test-openclash-config-rewrite.sh \
  tests/test-openclash-core-concurrency.sh \
  tests/test-openclash-sigsegv-fail-closed.sh \
  tests/test-openclash-watchdog-memory.sh \
  tests/test-quickstart-template-parser-fix.sh \
  tests/test-preflight-feed-root.sh \
  tests/test-final-rootfs-quickstart-render.sh; do
  grep -Fq 'FEED_CHECK_ROOT' "$root/$script" || fail "$script does not use FEED_CHECK_ROOT"
done

echo 'PREFLIGHT_LEGACY_PATH_REFERENCES=0'
echo 'PREFLIGHT_PATH_CONTRACT=PASS'
