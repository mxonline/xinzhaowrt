#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

FIRMWARE_VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")"
[[ -n "$FIRMWARE_VERSION" ]] || { echo "ERROR: VERSION is empty"; exit 1; }
export FIRMWARE_VERSION

USE_KNOWN_GOOD_LOCK="${USE_KNOWN_GOOD_LOCK:-0}"
LOCK_FILE="${KNOWN_GOOD_LOCK:-$PROJECT_ROOT/config/arthur-known-good.lock}"
if [[ "$USE_KNOWN_GOOD_LOCK" == "1" ]]; then
  [[ -f "$LOCK_FILE" ]] || { echo "ERROR: Known-Good lock missing: $LOCK_FILE"; exit 1; }
  # shellcheck disable=SC1090
  source "$LOCK_FILE"
  REQUESTED_REF="$IMMORTALWRT_REF"
else
  REQUESTED_REF="${1:-$SOURCE_REF}"
fi

WORKDIR="${WORKDIR:-$PROJECT_ROOT/work}"
SRC="$WORKDIR/immortalwrt"
OUT="$PROJECT_ROOT/output"
JOBS="${JOBS:-$(nproc)}"
QUIET_BUILD="${QUIET_BUILD:-0}"
REUSE_SOURCE="${REUSE_SOURCE:-1}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"

mkdir -p "$WORKDIR" "$OUT/logs"
rm -rf "$OUT/firmware"
mkdir -p "$OUT/firmware"

BUILD_LOG="$OUT/logs/build.log"
DIAGNOSTIC_LOG="$OUT/logs/build-diagnostic.log"
: > "$BUILD_LOG"
rm -f "$DIAGNOSTIC_LOG"
if [[ "$QUIET_BUILD" == "1" ]]; then
  exec >>"$BUILD_LOG" 2>&1
else
  exec > >(tee -a "$BUILD_LOG") 2>&1
fi

echo "[1/10] Acquire verified ImmortalWrt source at exact ref: $REQUESTED_REF"
bash "$PROJECT_ROOT/scripts/fetch-immortalwrt-source.sh" "$SRC" "$SOURCE_REPO" "$REQUESTED_REF" "$OUT"
# shellcheck disable=SC1090
source "$OUT/source-fetch.env"

cd "$SRC"
SOURCE_SHA="$SOURCE_COMMIT"
export CCACHE_DIR="$SRC/.ccache"
mkdir -p "$CCACHE_DIR"

if [[ "$USE_KNOWN_GOOD_LOCK" == "1" ]]; then
  echo "KNOWN_GOOD_LOCK: pinning standard feeds to exact commits"
  cat > feeds.conf <<EOF
src-git packages https://github.com/immortalwrt/packages.git^$PACKAGES_REF
src-git luci https://github.com/immortalwrt/luci.git^$LUCI_REF
src-git routing https://github.com/openwrt/routing.git^$ROUTING_REF
src-git telephony https://github.com/openwrt/telephony.git^$TELEPHONY_REF
src-git video https://github.com/openwrt/video.git^$VIDEO_REF
EOF
fi

echo "[2/10] Update/install standard feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "[3/10] Add mandatory external package sources"
USE_KNOWN_GOOD_LOCK="$USE_KNOWN_GOOD_LOCK" KNOWN_GOOD_LOCK="$LOCK_FILE" \
  "$PROJECT_ROOT/scripts/add-custom-packages.sh" "$SRC"
echo "[3/10] Refresh feeds and package indexes before existence check"
./scripts/feeds update -a
./scripts/feeds install -a
"$PROJECT_ROOT/scripts/apply-upload-oom-fix.sh" "$SRC"
"$PROJECT_ROOT/scripts/check-package-sources.sh" "$SRC"
"$PROJECT_ROOT/scripts/check-package-existence.sh" "$SRC"
"$PROJECT_ROOT/scripts/verify-project.sh"

echo "[4/10] Install project first-boot defaults overlay"
mkdir -p "$SRC/files"
rsync -a "$PROJECT_ROOT/files/" "$SRC/files/"

echo "[5/10] Apply Arthur target and 22-plugin seed config"
bash "$PROJECT_ROOT/tests/test-version-identity-defconfig.sh" "$SRC"
cp .config "$OUT/full.config"

echo "[6/10] Download source archives"
if ! make download -j"$JOBS"; then
  echo "Download pass failed; retrying serially with V=s."
  find dl -type f -size -1024c -print -delete || true
  make download -j1 V=s
fi
find dl -type f -size -1024c -print -delete || true

echo "[7/10] Compile firmware"
if ! make -j"$JOBS"; then
  echo "PARALLEL_BUILD_FAILED: rerunning with -j1 V=s to expose the first real error."
  : > "$DIAGNOSTIC_LOG"
  if make -j1 V=s 2>&1 | tee "$DIAGNOSTIC_LOG"; then
    echo "SERIAL_RETRY_RECOVERED: parallel failure was transient; continuing acceptance gates."
  else
    echo "BUILD_FAILED: serial diagnostic build also failed."
    "$PROJECT_ROOT/scripts/extract-build-error.sh" "$DIAGNOSTIC_LOG"
    exit 1
  fi
fi

"$PROJECT_ROOT/scripts/verify-upload-oom-build.sh" "$SRC"

FINAL_ROOTFS_DIR=""
while IFS= read -r release_file; do
  candidate_root="${release_file%/etc/openwrt_release}"
  if [[ -f "$candidate_root/etc/os-release" && -f "$candidate_root/etc/uci-defaults/99-xinzhao-defaults" ]]; then
    FINAL_ROOTFS_DIR="$candidate_root"
    break
  fi
done < <(find "$SRC/build_dir" -type f -path '*/etc/openwrt_release' -print)
[[ -n "$FINAL_ROOTFS_DIR" ]] || { echo "ERROR: final ${DEVICE_TARGET} rootfs staging directory was not found"; exit 1; }
bash "$PROJECT_ROOT/scripts/verify-final-rootfs-identity.sh" "$OUT/full.config" "$FINAL_ROOTFS_DIR"

echo "[8/10] Verify all mandatory LuCI plugins were compiled and embedded"
"$PROJECT_ROOT/scripts/verify-built-plugins.sh" "$SRC"

echo "[9/10] Collect and normalize firmware names"
TARGET_DIR="bin/targets/$DEVICE_TARGET/$DEVICE_SUBTARGET"
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: target output directory missing: $TARGET_DIR"; exit 1; }

found=0
while IFS= read -r -d '' image; do
  base="$(basename "$image")"
  case "$base" in
    *sysupgrade.bin) type="sysupgrade" ;;
    *factory.bin) type="factory" ;;
    *) type="$(printf '%s' "$base" | sed 's/[^A-Za-z0-9._-]/_/g')" ;;
  esac
  if [[ "$type" == "sysupgrade" || "$type" == "factory" ]]; then
    dest="$OUT/firmware/${FIRMWARE_ID}-${DEVICE_NAME}-v${FIRMWARE_VERSION}-${BUILD_DATE}-${type}.bin"
  else
    dest="$OUT/firmware/$base"
  fi
  cp -v "$image" "$dest"
  found=1
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "*${DEVICE_PROFILE}*" -print0)

[[ "$found" == "1" ]] || { echo "ERROR: no firmware matching ${DEVICE_PROFILE} was produced"; exit 1; }

for meta in sha256sums profiles.json; do
  [[ -f "$TARGET_DIR/$meta" ]] && cp -v "$TARGET_DIR/$meta" "$OUT/firmware/"
done

{
  echo "Firmware: $FIRMWARE_DISPLAY_NAME"
  echo "Firmware ID: $FIRMWARE_ID"
  echo "Version: v$FIRMWARE_VERSION"
  echo "Channel: $FIRMWARE_CHANNEL"
  echo "Build date UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Device: $DEVICE_VENDOR $DEVICE_MODEL ($DEVICE_NAME)"
  echo "Target: $DEVICE_TARGET/$DEVICE_SUBTARGET"
  echo "Profile: $DEVICE_PROFILE"
  echo "Default LAN IP: $DEFAULT_LAN_IP"
  echo "Default Wi-Fi SSID: $DEFAULT_WIFI_SSID"
  echo "Default Wi-Fi password: $DEFAULT_WIFI_PASSWORD"
  echo "Default admin user: $DEFAULT_ROOT_USER"
  echo "Upstream: $SOURCE_REPO"
  echo "Ref: $REQUESTED_REF"
  echo "Commit: $SOURCE_SHA"
  echo "Source method: $SOURCE_METHOD"
  echo "Source remote: $SOURCE_REMOTE"
  echo "Source integrity: $SOURCE_INTEGRITY"
  [[ -z "$SOURCE_ARCHIVE_SHA256" ]] || echo "Source archive SHA256: $SOURCE_ARCHIVE_SHA256"
  echo "Known-Good lock enabled: $USE_KNOWN_GOOD_LOCK"
  echo "Large-upload guard: disk-backed Nginx request buffering; official cgi-io /tmp O_TMPFILE and /tmp/firmware.bin same-filesystem handoff"
  if [[ "$USE_KNOWN_GOOD_LOCK" == "1" ]]; then
    echo "Lock file: config/arthur-known-good.lock"
  fi
  echo
  echo "Mandatory LuCI plugins:"
  sed 's/^/- /' "$PROJECT_ROOT/config/required-plugins.txt"
  echo
  echo "Custom package commits:"
  for d in .xinzhao-sources/*; do
    [[ -d "$d/.git" ]] || continue
    printf '%s: ' "$(basename "$d")"
    git -C "$d" rev-parse HEAD
  done
} > "$OUT/build-info.txt"

cp "$PROJECT_ROOT/config/required-plugins.txt" "$OUT/required-plugins.txt"
[[ -f "$LOCK_FILE" ]] && cp "$LOCK_FILE" "$OUT/arthur-known-good.lock"
(
  cd "$OUT/firmware"
  sha256sum * > SHA256SUMS.local
)

echo "[10/10] Done"
echo "Firmware: $OUT/firmware"
echo "Metadata: $OUT/build-info.txt"
echo "Plugin verification: $OUT/plugin-verification.txt"
echo "Upload OOM verification: $OUT/upload-oom-verification.txt"
