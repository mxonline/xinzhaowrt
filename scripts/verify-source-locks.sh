#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${XINZHAOWRT_SOURCES_LOCK:-$PROJECT_ROOT/config/sources.lock}"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"

[[ -f "$LOCK_FILE" ]] || { echo "ERROR: sources lock missing: $LOCK_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$LOCK_FILE"
set +a

check_repo() {
  local label="$1" dir="$2" expected="$3"
  [[ -d "$dir/.git" ]] || { echo "ERROR: $label repo missing: $dir" >&2; exit 1; }
  local actual
  actual="$(git -C "$dir" rev-parse HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $label revision mismatch: expected=$expected actual=$actual" >&2
    exit 1
  fi
  echo "LOCK_OK: $label $actual"
}

check_repo immortalwrt "$SRC" "$IMMORTALWRT_COMMIT"
check_repo feed-packages "$SRC/feeds/packages" "$PACKAGES_FEED_COMMIT"
check_repo feed-luci "$SRC/feeds/luci" "$LUCI_FEED_COMMIT"
check_repo feed-routing "$SRC/feeds/routing" "$ROUTING_FEED_COMMIT"
check_repo feed-telephony "$SRC/feeds/telephony" "$TELEPHONY_FEED_COMMIT"
check_repo feed-video "$SRC/feeds/video" "$VIDEO_FEED_COMMIT"

check_repo kenzok8 "$SRC/.xinzhao-sources/kenzok8-openwrt-packages" "$KENZOK8_COMMIT"
check_repo istore "$SRC/.xinzhao-sources/istore" "$ISTORE_COMMIT"
check_repo immortalwrt-luci "$SRC/.xinzhao-sources/immortalwrt-luci" "$LUCI_FEED_COMMIT"
check_repo immortalwrt-packages "$SRC/.xinzhao-sources/immortalwrt-packages" "$PACKAGES_FEED_COMMIT"
check_repo diskman "$SRC/.xinzhao-sources/luci-app-diskman" "$DISKMAN_COMMIT"
check_repo easytier "$SRC/.xinzhao-sources/luci-app-easytier" "$EASYTIER_COMMIT"
check_repo mosdns "$SRC/.xinzhao-sources/luci-app-mosdns" "$MOSDNS_COMMIT"
check_repo v2ray-geodata "$SRC/.xinzhao-sources/v2ray-geodata" "$V2RAY_GEODATA_COMMIT"
check_repo openclash "$SRC/.xinzhao-sources/OpenClash" "$OPENCLASH_COMMIT"
check_repo openappfilter "$SRC/.xinzhao-sources/OpenAppFilter" "$OAF_COMMIT"

echo "PASS: all v3.0 source locks match"
