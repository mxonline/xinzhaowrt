#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="${1:?usage: $0 <sysupgrade.bin> <unsquashfs>}"
UNSQUASHFS="${2:?usage: $0 <sysupgrade.bin> <unsquashfs>}"
[[ -s "$IMAGE" ]] || { echo "ERROR: missing firmware image: $IMAGE" >&2; exit 1; }
if [[ ! -x "$UNSQUASHFS" ]]; then
  UNSQUASHFS="$(command -v unsquashfs || true)"
fi
[[ -n "$UNSQUASHFS" && -x "$UNSQUASHFS" ]] || { echo "ERROR: missing unsquashfs verifier dependency" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
member="$(tar -tf "$IMAGE" | awk '/\/root$/ { print; exit }')"
[[ -n "$member" ]] || { echo 'ERROR: sysupgrade image has no rootfs member' >&2; exit 1; }
tar -xOf "$IMAGE" "$member" > "$tmp/root.squashfs"
info="$($UNSQUASHFS -cat "$tmp/root.squashfs" www/luci-static/xinzhao/build-info.json)"
[[ -n "$info" ]] || { echo 'ERROR: firmware rootfs build-info is empty' >&2; exit 1; }
if grep -Eq '@VERSION@|@BUILD_DATE@|@GIT_COMMIT@|@BUILD_ID@' <<<"$info"; then echo 'ERROR: firmware rootfs build-info contains unresolved placeholders' >&2; exit 1; fi
grep -Fq '"Firmware": "XinZhaoWrt"' <<<"$info" || { echo 'ERROR: firmware rootfs build-info firmware mismatch' >&2; exit 1; }
grep -Fq '"Profile": "jdcloud_re-ss-01"' <<<"$info" || { echo 'ERROR: firmware rootfs build-info profile mismatch' >&2; exit 1; }
echo "PASS: firmware rootfs build-info is concrete: $(basename "$IMAGE")"
