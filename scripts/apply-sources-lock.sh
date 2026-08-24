#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${XINZHAOWRT_SOURCES_LOCK:-$PROJECT_ROOT/config/sources.lock}"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"

[[ -f "$LOCK_FILE" ]] || { echo "ERROR: sources lock missing: $LOCK_FILE" >&2; exit 1; }
[[ -f "$SRC/feeds.conf.default" ]] || { echo "ERROR: feeds.conf.default missing under $SRC" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$LOCK_FILE"
set +a

required=(
  IMMORTALWRT_COMMIT PACKAGES_FEED_COMMIT LUCI_FEED_COMMIT
  ROUTING_FEED_COMMIT TELEPHONY_FEED_COMMIT VIDEO_FEED_COMMIT
)
for key in "${required[@]}"; do
  [[ "${!key:-}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: invalid or missing $key in $LOCK_FILE" >&2
    exit 1
  }
done

cat > "$SRC/feeds.conf" <<EOF
src-git packages https://github.com/immortalwrt/packages.git^${PACKAGES_FEED_COMMIT}
src-git luci https://github.com/immortalwrt/luci.git^${LUCI_FEED_COMMIT}
src-git routing https://github.com/openwrt/routing.git^${ROUTING_FEED_COMMIT}
src-git telephony https://github.com/openwrt/telephony.git^${TELEPHONY_FEED_COMMIT}
src-git video https://github.com/openwrt/video.git^${VIDEO_FEED_COMMIT}
EOF

echo "Pinned standard feeds from $LOCK_FILE"
cat "$SRC/feeds.conf"
