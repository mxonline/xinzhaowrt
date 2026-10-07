#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt /path/to/project/openclash-core}"
PROJECT_PACKAGE="${2:?Usage: $0 /path/to/immortalwrt /path/to/project/openclash-core}"

fail() {
  echo "NO_AMBIGUOUS_PACKAGE_SOURCE=FAIL -- $*" >&2
  exit 1
}

[[ -d "$SRC" ]] || fail "source root is missing: $SRC"
[[ -f "$PROJECT_PACKAGE/Makefile" ]] || fail "project package Makefile is missing: $PROJECT_PACKAGE/Makefile"

source_package="$SRC/package/xinzhao/openclash-core"
authority=""
if [[ -f "$source_package/Makefile" ]]; then
  authority="$(readlink -f "$source_package")"
fi
[[ -n "$authority" ]] || fail "source package authority is missing: $source_package"

expected_makefile_sha="$(sha256sum "$PROJECT_PACKAGE/Makefile" | awk '{print $1}')"
selected_makefile="${OPENCLASH_SELECTED_MAKEFILE:-}"
if [[ -z "$selected_makefile" ]]; then
  fail "selected Core Makefile provenance is missing"
fi
[[ -f "$selected_makefile" ]] || fail "selected Core Makefile is missing: $selected_makefile"
selected_makefile_realpath="$(readlink -f "$selected_makefile")"
selected_makefile_sha="$(sha256sum "$selected_makefile_realpath" | awk '{print $1}')"
[[ "$selected_makefile_sha" == "$expected_makefile_sha" ]] || fail "selected Core Makefile differs from project package"
paths=(
  "$source_package"
  "$SRC/package/feeds/xinzhao/openclash-core"
  "$SRC/.xinzhao-feed/openclash-core"
)
seen=0
for path in "${paths[@]}"; do
  [[ -e "$path" || -L "$path" ]] || continue
  [[ -f "$path/Makefile" ]] || fail "registered Core source has no Makefile: $path"
  resolved="$(readlink -f "$path")"
  actual_makefile_sha="$(sha256sum "$path/Makefile" | awk '{print $1}')"
  [[ "$actual_makefile_sha" == "$expected_makefile_sha" ]] || fail "Core Makefile differs from project package: $path"
  if [[ "$resolved" == "$authority" ]]; then
    printf 'OPENCLASH_CORE_ALIAS=%s -> %s\n' "$path" "$resolved"
  elif diff -qr "$authority" "$resolved" >/dev/null 2>&1; then
    printf 'OPENCLASH_CORE_MIRROR=%s -> %s\n' "$path" "$resolved"
  else
    fail "independent Core source differs from authority: $path resolves to $resolved; authority is $authority"
  fi
  seen=$((seen + 1))
done

[[ "$seen" -ge 1 ]] || fail "no registered Core package paths were found"

printf 'OPENCLASH_CORE_PACKAGE_AUTHORITY=%s\n' "$authority"
printf 'OPENCLASH_CORE_MAKEFILE_SHA256=%s\n' "$expected_makefile_sha"
printf 'OPENCLASH_SELECTED_MAKEFILE_REALPATH=%s\n' "$selected_makefile_realpath"
printf 'OPENCLASH_SELECTED_MAKEFILE_SHA256=%s\n' "$selected_makefile_sha"
printf 'NO_AMBIGUOUS_PACKAGE_SOURCE=PASS\n'
