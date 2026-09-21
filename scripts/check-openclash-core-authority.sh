#!/usr/bin/env bash
set -Eeuo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
AUTHORITY="$SRC/package/xinzhao/openclash-core"
[[ -f "$AUTHORITY/Makefile" ]] || {
  echo "OPENCLASH_CORE_PACKAGE_AUTHORITY=FAIL -- missing $AUTHORITY/Makefile" >&2
  exit 1
}

authority_real="$(readlink -f "$AUTHORITY")"
ambiguous=0

for mirror in "$SRC/.xinzhao-feed/openclash-core" "$SRC/package/feeds/xinzhao/openclash-core"; do
  if [[ -e "$mirror" || -L "$mirror" ]]; then
    mirror_real="$(readlink -f "$mirror" 2>/dev/null || true)"
    echo "AMBIGUOUS_OPENCLASH_CORE_SOURCE=$mirror -> ${mirror_real:-<unresolved>}" >&2
    ambiguous=1
  fi
done

while IFS= read -r makefile; do
  pkgdir="${makefile%/Makefile}"
  [[ "$(readlink -f "$pkgdir")" == "$authority_real" ]] && continue
  echo "AMBIGUOUS_OPENCLASH_CORE_SOURCE=$makefile" >&2
  ambiguous=1
done < <(find "$SRC/package" -type f -path '*/openclash-core/Makefile' -print 2>/dev/null | sort)

(( ambiguous == 0 )) || {
  echo "NO_AMBIGUOUS_PACKAGE_SOURCE=FAIL" >&2
  exit 1
}

echo "OPENCLASH_CORE_PACKAGE_AUTHORITY=$authority_real"
echo "NO_AMBIGUOUS_PACKAGE_SOURCE=PASS"
