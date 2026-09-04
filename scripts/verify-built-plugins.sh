#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
REQUIRED_FILE="$PROJECT_ROOT/config/required-plugins.txt"
TARGET_DIR="$SRC/bin/targets/$DEVICE_TARGET/$DEVICE_SUBTARGET"
REPORT="$PROJECT_ROOT/output/plugin-verification.txt"

[[ -d "$SRC" ]] || { echo "ERROR: OpenWrt source directory missing: $SRC"; exit 1; }
[[ -f "$REQUIRED_FILE" ]] || { echo "ERROR: required plugin list missing: $REQUIRED_FILE"; exit 1; }
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: target output directory missing: $TARGET_DIR"; exit 1; }

mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"

mapfile -t manifests < <(
  find "$TARGET_DIR" -maxdepth 1 -type f \
    \( -name "*${DEVICE_PROFILE}*.manifest" -o -name '*.manifest' \) \
    -print | sort -u
)

if (( ${#manifests[@]} == 0 )); then
  echo "ERROR: no firmware package manifest was generated in $TARGET_DIR" | tee -a "$REPORT"
  echo "A successful make alone is not enough; the final image must expose its installed package manifest." | tee -a "$REPORT"
  exit 1
fi

{
  echo "Arthur required-plugin final verification"
  echo "Target: $DEVICE_TARGET/$DEVICE_SUBTARGET/$DEVICE_PROFILE"
  echo "Manifest files:"
  printf '  - %s\n' "${manifests[@]}"
  echo
} >> "$REPORT"

missing_archive=0
missing_manifest=0
verified=0
language_package='luci-i18n-base-zh-cn'
language_resource='usr/lib/lua/luci/i18n/base.zh-cn.lmo'

while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue

  archive=''
  while IFS= read -r candidate; do
    archive="$candidate"
    break
  done < <(
    find "$SRC/bin" -type f \
      \( -name "${pkg}_*.ipk" -o -name "${pkg}-*.apk" \) \
      -print 2>/dev/null | sort
  )

  manifest_hit=''
  for manifest in "${manifests[@]}"; do
    if grep -Eq "^${pkg}([[:space:]]|[=-])" "$manifest"; then
      manifest_hit="$manifest"
      break
    fi
  done

  if [[ -z "$archive" ]]; then
    echo "MISSING_BUILT_PACKAGE: $pkg" | tee -a "$REPORT"
    missing_archive=1
  fi

  if [[ -z "$manifest_hit" ]]; then
    echo "MISSING_FROM_FIRMWARE_MANIFEST: $pkg" | tee -a "$REPORT"
    missing_manifest=1
  fi

  if [[ -n "$archive" && -n "$manifest_hit" ]]; then
    echo "PASS: $pkg | archive=$archive | manifest=$manifest_hit" >> "$REPORT"
    verified=$((verified + 1))
  fi
done < "$REQUIRED_FILE"

language_archive=''
while IFS= read -r candidate; do
  language_archive="$candidate"
  break
done < <(
  find "$SRC/bin" -type f -name "${language_package}_*.ipk" -print 2>/dev/null | sort
)

language_manifest=''
for manifest in "${manifests[@]}"; do
  if grep -Eq "^${language_package}([[:space:]]|[=-])" "$manifest"; then
    language_manifest="$manifest"
    break
  fi
done

if [[ -z "$language_archive" ]]; then
  echo "MISSING_BUILT_PACKAGE: $language_package" | tee -a "$REPORT"
  missing_archive=1
else
  data_member="$(ar t "$language_archive" | awk '/^data\.tar/{print; exit}')"
  if [[ -z "$data_member" ]] || ! ar p "$language_archive" "$data_member" | tar -tzf - | sed 's#^\./##' | grep -qxF "$language_resource"; then
    echo "MISSING_TRANSLATION_RESOURCE: $language_resource in $language_package" | tee -a "$REPORT"
    missing_archive=1
  else
    echo "PASS: $language_package contains $language_resource" >> "$REPORT"
  fi
fi

if [[ -z "$language_manifest" ]]; then
  echo "MISSING_FROM_FIRMWARE_MANIFEST: $language_package" | tee -a "$REPORT"
  missing_manifest=1
else
  echo "PASS: $language_package | manifest=$language_manifest" >> "$REPORT"
fi

{
  echo
  echo "Verified required plugins: $verified"
} >> "$REPORT"

if (( missing_archive || missing_manifest )); then
  echo "ERROR: final required-plugin verification failed." | tee -a "$REPORT"
  echo "The build must not be published unless every required LuCI plugin has both a compiled package archive and an entry in the firmware manifest." | tee -a "$REPORT"
  exit 1
fi

echo "PASS: all required LuCI plugins were compiled and are present in the final firmware manifest." | tee -a "$REPORT"
