#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_tree="$(mktemp -d)"
trap 'rm -rf "$source_tree"' EXIT

fixture_luci="$source_tree/feeds/luci"
fixture_parser="$fixture_luci/modules/luci-lua-runtime/src/template_utils.c"
feed_check_root="${FEED_CHECK_ROOT:-$root/work/immortalwrt}"
source_parser="$feed_check_root/feeds/luci/modules/luci-lua-runtime/src/template_utils.c"
mkdir -p "$(dirname "$fixture_parser")"
[[ -s "$source_parser" ]] || {
  echo "PREFLIGHT_FEED_ROOT_TEST: FAIL -- parser fixture source is missing: $source_parser" >&2
  exit 1
}
cp "$source_parser" "$fixture_parser"
git -C "$fixture_luci" init -q
git -C "$fixture_luci" apply --reverse "$root/patches/luci/0001-template-parser-escape-crlf.patch"

output="$(FEED_CHECK_ROOT="$source_tree" bash "$root/tests/test-quickstart-template-parser-fix.sh" 2>&1)"
grep -Fq "LUCI_TEMPLATE_FIX=APPLIED target=modules/luci-lua-runtime/src/template_utils.c" <<<"$output" || {
  echo 'PREFLIGHT_FEED_ROOT_TEST: FAIL -- parser test ignored FEED_CHECK_ROOT' >&2
  echo "$output" >&2
  exit 1
}
grep -Fq 'LUCI_TEMPLATE_CRLF_ESCAPE=PASS' <<<"$output" || {
  echo 'PREFLIGHT_FEED_ROOT_TEST: FAIL -- Feed Check parser fixture was not validated' >&2
  echo "$output" >&2
  exit 1
}

missing="$source_tree/missing-feed-check"
missing_output="$source_tree/missing-feed-check.out"
if FEED_CHECK_ROOT="$missing" bash "$root/tests/test-quickstart-template-parser-fix.sh" >"$missing_output" 2>&1; then
  echo 'PREFLIGHT_FEED_ROOT_TEST: FAIL -- missing Feed Check root was silently accepted' >&2
  cat "$missing_output" >&2
  exit 1
fi
grep -Fq 'ERROR: LuCI feed is missing:' "$missing_output" || {
  echo 'PREFLIGHT_FEED_ROOT_TEST: FAIL -- missing Feed Check root did not report a clear error' >&2
  cat "$missing_output" >&2
  exit 1
}

echo 'PREFLIGHT_FEED_ROOT_TEST: PASS'
