#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

LOCK_FILE="${KNOWN_GOOD_LOCK:-$PROJECT_ROOT/config/arthur-known-good.lock}"
[[ -f "$LOCK_FILE" ]] || { echo "ERROR: missing frozen feed lock: $LOCK_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LOCK_FILE"

[[ "$SOURCE_REF" == "$IMMORTALWRT_REF" ]] || {
  echo "ERROR: build.env SOURCE_REF and frozen IMMORTALWRT_REF differ" >&2
  exit 1
}
[[ "$DEVICE_TARGET/$DEVICE_SUBTARGET" == 'qualcommax/ipq60xx' ]] || {
  echo "ERROR: unexpected Arthur target: $DEVICE_TARGET/$DEVICE_SUBTARGET" >&2
  exit 1
}
[[ "$DEVICE_PROFILE" == 'jdcloud_re-ss-01' ]] || {
  echo "ERROR: unexpected Arthur profile: $DEVICE_PROFILE" >&2
  exit 1
}

OUT_DIR="${ZRAM_CLOSURE_OUTPUT_DIR:-$PROJECT_ROOT/output/zram-closure}"
WORK_ROOT="${ZRAM_CLOSURE_WORK_ROOT:-$PROJECT_ROOT/work/zram-closure}"
SRC="$WORK_ROOT/immortalwrt"
JOBS="${JOBS:-2}"
mkdir -p "$OUT_DIR/logs" "$WORK_ROOT"
LOG_FILE="$OUT_DIR/logs/closure.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  echo "ZRAM_CLOSURE=FAIL"
  echo "ERROR: $*" >&2
  exit 1
}

run_make() {
  local target="$1"
  shift
  case "$target" in
    world|target/install|target/linux/install|package/install|tools/install|toolchain/install)
      fail "forbidden make target requested: $target"
      ;;
  esac
  printf 'MAKE_TARGET=%s\n' "$target"
  make "$target" "$@"
}

assert_no_firmware_artifacts() {
  local image
  image="$(find "$SRC/bin" "$OUT_DIR" -type f \( -name '*sysupgrade*.bin' -o -name '*factory*.bin' \) -print -quit 2>/dev/null || true)"
  [[ -z "$image" ]] || fail "firmware image artifact appeared during closure: $image"
}

require_config() {
  local expected="$1"
  grep -qxF "$expected" "$SRC/.config" || fail "defconfig removed required setting: $expected"
}

echo "CLOSURE_SOURCE_REPO=$SOURCE_REPO"
echo "CLOSURE_SOURCE_REF=$SOURCE_REF"
echo "CLOSURE_FEED_LOCK=$LOCK_FILE"
echo "TARGET=$DEVICE_TARGET/$DEVICE_SUBTARGET"
echo "PROFILE=$DEVICE_PROFILE"

rm -rf "$SRC"
bash "$PROJECT_ROOT/scripts/fetch-immortalwrt-source.sh" \
  "$SRC" "$SOURCE_REPO" "$SOURCE_REF" "$OUT_DIR"

cd "$SRC"
cat > feeds.conf <<EOF
src-git packages https://github.com/immortalwrt/packages.git^$PACKAGES_REF
src-git luci https://github.com/immortalwrt/luci.git^$LUCI_REF
src-git routing https://github.com/openwrt/routing.git^$ROUTING_REF
src-git telephony https://github.com/openwrt/telephony.git^$TELEPHONY_REF
src-git video https://github.com/openwrt/video.git^$VIDEO_REF
EOF

./scripts/feeds update -a
./scripts/feeds install -a
USE_KNOWN_GOOD_LOCK=1 KNOWN_GOOD_LOCK="$LOCK_FILE" \
  bash "$PROJECT_ROOT/scripts/add-custom-packages.sh" "$SRC"

mkdir -p "$SRC/package/xinzhao"
rsync -a "$PROJECT_ROOT/package/xinzhao/luci-app-adguardhome-manager/" \
  "$SRC/package/xinzhao/luci-app-adguardhome-manager/"
rsync -a "$PROJECT_ROOT/package/xinzhao/openclash-core/" \
  "$SRC/package/xinzhao/openclash-core/"
ln -sfn "$SRC/package/xinzhao/luci-app-adguardhome-manager" \
  "$SRC/.xinzhao-feed/luci-app-adguardhome-manager"
ln -sfn "$SRC/package/xinzhao/openclash-core" \
  "$SRC/.xinzhao-feed/openclash-core"
./scripts/feeds update xinzhao
./scripts/feeds install -f -p xinzhao luci-app-adguardhome-manager openclash-core
bash "$PROJECT_ROOT/scripts/check-package-sources.sh" "$SRC"

mkdir -p "$SRC/files"
rsync -a "$PROJECT_ROOT/files/" "$SRC/files/"
bash "$PROJECT_ROOT/scripts/apply-arthur-config.sh" "$SRC"

require_config 'CONFIG_PACKAGE_kmod-zram=y'
require_config 'CONFIG_PACKAGE_zram-swap=y'
require_config 'CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y'
require_config 'CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y'
require_config 'CONFIG_TARGET_qualcommax=y'
require_config 'CONFIG_TARGET_qualcommax_ipq60xx=y'
require_config 'CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y'

grep -Fq "uci -q set system.@system[0].zram_size_mb='192'" \
  "$SRC/files/etc/uci-defaults/98-xinzhao-zram-defaults" || fail '192 MiB default missing from staged source'
grep -Fq "uci -q set system.@system[0].zram_comp_algo='lz4'" \
  "$SRC/files/etc/uci-defaults/98-xinzhao-zram-defaults" || fail 'LZ4 default missing from staged source'

assert_no_firmware_artifacts
run_make target/linux/prepare V=s -j"$JOBS"
run_make target/linux/compile V=s -j"$JOBS"
run_make package/kernel/linux/prepare V=s -j"$JOBS"
run_make package/kernel/linux/compile V=s -j"$JOBS"
run_make package/system/zram-swap/compile V=s -j"$JOBS"
assert_no_firmware_artifacts

KMOD_ARTIFACT="$(find "$SRC/bin" "$SRC/build_dir" -type f \( -name 'kmod-zram_*.apk' -o -name 'kmod-zram_*.ipk' \) -print -quit 2>/dev/null || true)"
LZ4_ARTIFACT="$(find "$SRC/bin" "$SRC/build_dir" -type f \( -name 'kmod-lib-lz4_*.apk' -o -name 'kmod-lib-lz4_*.ipk' \) -print -quit 2>/dev/null || true)"
ZRAM_ARTIFACT="$(find "$SRC/bin" "$SRC/build_dir" -type f \( -name 'zram-swap_*.apk' -o -name 'zram-swap_*.ipk' \) -print -quit 2>/dev/null || true)"
ZRAM_KO="$(find "$SRC/build_dir" -type f -path '*/drivers/block/zram/zram.ko' -print -quit 2>/dev/null || true)"
[[ -n "$KMOD_ARTIFACT" && -n "$ZRAM_KO" ]] || fail 'kmod-zram package or zram.ko artifact is missing'
[[ -n "$LZ4_ARTIFACT" ]] || fail 'kmod-lib-lz4 dependency artifact is missing'
[[ -n "$ZRAM_ARTIFACT" ]] || fail 'zram-swap package artifact is missing'

printf '%s\n' \
  'ZRAM_CONFIG_INCLUDED=PASS' \
  'KMOD_ZRAM_COMPILE=PASS' \
  'ZRAM_SWAP_PACKAGE_COMPILE=PASS' \
  'KERNEL_DEPENDENCY_CLOSURE=PASS' \
  'TARGET=qualcommax/ipq60xx' \
  'PROFILE=jdcloud_re-ss-01' \
  'FIRMWARE_BUILD_COUNT_NEW=0' \
  "SOURCE_REF=$SOURCE_REF" \
  "SOURCE_SHA=$(git -C "$SRC" rev-parse HEAD)" \
  "KMOD_ZRAM_ARTIFACT=$KMOD_ARTIFACT" \
  "LZ4_ARTIFACT=$LZ4_ARTIFACT" \
  "ZRAM_SWAP_ARTIFACT=$ZRAM_ARTIFACT" \
  "ZRAM_KO=$ZRAM_KO" > "$OUT_DIR/markers.txt"

cat "$OUT_DIR/markers.txt"
echo 'ZRAM_CLOSURE=PASS'
