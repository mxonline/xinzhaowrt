#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/project/package/xinzhao/openclash-core" \
  "$tmp/source/package/xinzhao" "$tmp/source/package/feeds/xinzhao" "$tmp/source/.xinzhao-feed"
printf '%s\n' 'define Package/openclash-core' 'endef' > "$tmp/project/package/xinzhao/openclash-core/Makefile"
mkdir -p "$tmp/source/package/xinzhao/openclash-core"
cp "$tmp/project/package/xinzhao/openclash-core/Makefile" "$tmp/source/package/xinzhao/openclash-core/Makefile"
cp -R "$tmp/source/package/xinzhao/openclash-core" "$tmp/source/package/feeds/xinzhao/openclash-core"
cp -R "$tmp/source/package/xinzhao/openclash-core" "$tmp/source/.xinzhao-feed/openclash-core"

[[ -x "$root/scripts/check-openclash-core-authority.sh" ]] || {
  echo 'check-openclash-core-authority.sh is missing' >&2
  exit 1
}

OPENCLASH_SELECTED_MAKEFILE="$tmp/source/package/xinzhao/openclash-core/Makefile" \
  "$root/scripts/check-openclash-core-authority.sh" "$tmp/source" "$tmp/project/package/xinzhao/openclash-core"

printf '%s\n' 'conflict' >> "$tmp/source/.xinzhao-feed/openclash-core/Makefile"
if OPENCLASH_SELECTED_MAKEFILE="$tmp/source/package/xinzhao/openclash-core/Makefile" \
  "$root/scripts/check-openclash-core-authority.sh" "$tmp/source" "$tmp/project/package/xinzhao/openclash-core"; then
  echo 'conflicting Core mirror was accepted' >&2
  exit 1
fi
echo 'OPENCLASH_CORE_AUTHORITY_CONFLICT=PASS'

grep -Fq 'check-openclash-core-authority.sh' "$root/scripts/build.sh"
grep -Fq 'check-openclash-core-authority.sh' "$root/scripts/check-package-sources.sh"
echo 'OPENCLASH_CORE_AUTHORITY_WIRING=PASS'
