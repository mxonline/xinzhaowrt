#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

REQUESTED_REF="${1:-$SOURCE_REF}"
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

"$PROJECT_ROOT/scripts/verify-project.sh"

if [[ "$REUSE_SOURCE" == "1" && -d "$SRC/.git" ]]; then
  echo "[1/9] Reuse ImmortalWrt checkout and reset to $REQUESTED_REF"
  git -C "$SRC" fetch --depth=1 origin "$REQUESTED_REF"
  git -C "$SRC" reset --hard FETCH_HEAD
  git -C "$SRC" clean -fdx -e dl/ -e .ccache/ -e .xinzhao-sources/
else
  echo "[1/9] Clone ImmortalWrt source: $REQUESTED_REF"
  rm -rf "$SRC"
  git clone --depth=1 --branch "$REQUESTED_REF" "$SOURCE_REPO" "$SRC"
fi

cd "$SRC"
SOURCE_SHA="$(git rev-parse HEAD)"
export CCACHE_DIR="$SRC/.ccache"
mkdir -p "$CCACHE_DIR"

echo "[2/9] Update/install standard feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "[3/9] Add mandatory external package sources"
"$PROJECT_ROOT/scripts/add-custom-packages.sh" "$SRC"
"$PROJECT_ROOT/scripts/check-package-sources.sh" "$SRC"
"$PROJECT_ROOT/scripts/check-package-existence.sh" "$SRC"

echo "[4/9] Install project first-boot defaults overlay"
mkdir -p "$SRC/files"
# Merge our overlay without deleting upstream files/.
rsync -a "$PROJECT_ROOT/files/" "$SRC/files/"

echo "[5/9] Apply Arthur target and 22-plugin seed config"
cp "$PROJECT_ROOT/config/arthur.config" .config
make defconfig
"$PROJECT_ROOT/scripts/check-config.sh" .config
cp .config "$OUT/full.config"

echo "[6/9] Download source archives"
if ! make download -j"$JOBS"; then
  echo "Download pass failed; retrying serially for clearer diagnostics."
  find dl -type f -size -1024c -print -delete || true
  make download -j1 V=s
fi
find dl -type f -size -1024c -print -delete || true

echo "[7/9] Compile firmware"
BUILD_LOG="$OUT/logs/build.log"
if [[ "$QUIET_BUILD" == "1" ]]; then
  if ! make -j"$JOBS" >"$BUILD_LOG" 2>&1; then
    echo "BUILD_FAILED: concise diagnostics follow"
    "$PROJECT_ROOT/scripts/extract-build-error.sh" "$BUILD_LOG"
    exit 1
  fi
else
  if ! make -j"$JOBS" 2>&1 | tee "$BUILD_LOG"; then
    echo "BUILD_FAILED: see $BUILD_LOG"
    "$PROJECT_ROOT/scripts/extract-build-error.sh" "$BUILD_LOG"
    exit 1
  fi
fi

echo "[8/9] Collect and normalize firmware names"
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
  echo "Default admin user: $DEFAULT_ROOT_USER"
  echo "Upstream: $SOURCE_REPO"
  echo "Ref: $REQUESTED_REF"
  echo "Commit: $SOURCE_SHA"
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
(
  cd "$OUT/firmware"
  sha256sum * > SHA256SUMS.local
)

echo "[9/9] Done"
echo "Firmware: $OUT/firmware"
echo "Metadata: $OUT/build-info.txt"
