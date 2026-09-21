#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build.sh"
CHECK="$ROOT/scripts/check-openclash-core-authority.sh"

grep -Fq 'package/xinzhao/openclash-core' "$BUILD"
! grep -Fq 'ln -sfn "$SRC/package/xinzhao/openclash-core"' "$BUILD"
! grep -Fq 'feeds install -f -p xinzhao luci-app-adguardhome-manager openclash-core' "$BUILD"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/package/xinzhao/openclash-core" "$tmp/.xinzhao-feed" "$tmp/package/feeds/xinzhao"
printf 'PKG_NAME:=openclash-core\n' > "$tmp/package/xinzhao/openclash-core/Makefile"
bash "$CHECK" "$tmp" | grep -q '^NO_AMBIGUOUS_PACKAGE_SOURCE=PASS$'
ln -s "$tmp/package/xinzhao/openclash-core" "$tmp/.xinzhao-feed/openclash-core"
if bash "$CHECK" "$tmp" >/dev/null 2>&1; then
  echo 'FAIL: duplicate feed registration was accepted' >&2
  exit 1
fi
echo 'OPENCLASH_CORE_PACKAGE_AUTHORITY_TEST=PASS'
