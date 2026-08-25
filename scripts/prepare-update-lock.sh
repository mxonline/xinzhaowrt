#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-rebuild_known_good}"
OUT="${2:-$ROOT/output/arthur-update.lock}"
BASE_LOCK="$ROOT/config/arthur-known-good.lock"

[[ -s "$BASE_LOCK" ]] || {
  echo "ERROR: missing Known-Good lock: $BASE_LOCK" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
cp "$BASE_LOCK" "$OUT"

latest_commit() {
  local url="$1"
  local sha
  sha="$(git ls-remote "$url" HEAD | awk 'NR==1 {print $1}')"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: unable to resolve HEAD for $url" >&2
    exit 1
  }
  printf '%s' "$sha"
}

set_ref() {
  local key="$1"
  local url="$2"
  local sha
  sha="$(latest_commit "$url")"

  grep -qE "^${key}=\"[0-9a-f]{40}\"$" "$OUT" || {
    echo "ERROR: lock key missing or malformed: $key" >&2
    exit 1
  }

  sed -i -E "s|^${key}=\"[0-9a-f]{40}\"$|${key}=\"${sha}\"|" "$OUT"
  echo "UPDATED_REF: ${key}=${sha}"
}

update_immortalwrt() {
  set_ref IMMORTALWRT_REF https://github.com/VIKINGYFY/immortalwrt.git
}

update_feeds() {
  set_ref PACKAGES_REF https://github.com/immortalwrt/packages.git
  set_ref LUCI_REF https://github.com/immortalwrt/luci.git
  set_ref ROUTING_REF https://github.com/openwrt/routing.git
  set_ref TELEPHONY_REF https://github.com/openwrt/telephony.git
  set_ref VIDEO_REF https://github.com/openwrt/video.git
}

update_plugins() {
  set_ref KENZOK8_REF https://github.com/kenzok8/openwrt-packages.git
  set_ref ISTORE_REF https://github.com/linkease/istore.git
  set_ref DISKMAN_REF https://github.com/sbwml/luci-app-diskman.git
  set_ref EASYTIER_REF https://github.com/EasyTier/luci-app-easytier.git
  set_ref MOSDNS_REF https://github.com/sbwml/luci-app-mosdns.git
  set_ref V2RAY_GEODATA_REF https://github.com/sbwml/v2ray-geodata.git
  set_ref OPENCLASH_REF https://github.com/vernesong/OpenClash.git
  set_ref OPENAPPFILTER_REF https://github.com/destan19/OpenAppFilter.git
}

case "$MODE" in
  rebuild_known_good)
    echo 'MODE: rebuild_known_good; all source refs remain frozen.'
    ;;
  update_immortalwrt)
    update_immortalwrt
    ;;
  update_feeds)
    update_feeds
    ;;
  update_plugins)
    update_plugins
    ;;
  update_all)
    update_immortalwrt
    update_feeds
    update_plugins
    ;;
  *)
    echo "ERROR: unsupported update mode: $MODE" >&2
    exit 1
    ;;
esac

[[ "$(grep -cE '^[A-Z0-9_]+_REF=\"[0-9a-f]{40}\"$' "$OUT")" -eq 14 ]] || {
  echo 'ERROR: candidate lock does not contain exactly 14 pinned refs.' >&2
  exit 1
}

printf 'CANDIDATE_LOCK=%s\n' "$OUT"
printf 'CANDIDATE_LOCK_SHA256=%s\n' "$(sha256sum "$OUT" | awk '{print $1}')"
