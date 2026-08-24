#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_VERSION="$(tr -d '\r\n ' < VERSION)"
if [[ -z "$BASE_VERSION" ]]; then
  echo "ERROR: VERSION is empty"
  exit 1
fi

RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}"
RUN_ID="${GITHUB_RUN_ID:-unknown}"
TAG="v${BASE_VERSION}-rc.${RUN_NUMBER}"
RELEASE_NAME="XinZhaoWrt Arthur ${TAG}"
FIRMWARE_DIR="output/firmware"

mapfile -t FIRMWARES < <(find "$FIRMWARE_DIR" -maxdepth 1 -type f -name '*jdcloud_re-ss-01*.bin' -size +0c | sort)
if (( ${#FIRMWARES[@]} == 0 )); then
  echo "ERROR: no non-empty jdcloud_re-ss-01 firmware found in $FIRMWARE_DIR"
  exit 1
fi

mkdir -p output/release
SHA_FILE="output/release/sha256sums.txt"
: > "$SHA_FILE"
for file in "${FIRMWARES[@]}"; do
  sha256sum "$file" >> "$SHA_FILE"
done

NOTES="output/release/release-notes.md"
cat > "$NOTES" <<EOF
# XinZhaoWrt Arthur ${TAG}

Candidate 预发布版本，仅表示云端编译与产物检查通过，尚未自动视为实机验证通过或 known-good。

- Device: JDCloud RE-SS-01 (Arthur)
- Target: qualcommax / ipq60xx
- Source ref: ${IMMORTAL_SOURCE_REF:-main}
- GitHub Actions Run ID: ${RUN_ID}
- Controller policy: automatic Candidate release

实机验证通过后，再晋升为 Stable / Latest 并更新 production/known-good.json。
EOF

ASSETS=("${FIRMWARES[@]}" "$SHA_FILE")
for optional in output/full.config output/build-info.txt output/required-plugins.txt; do
  [[ -s "$optional" ]] && ASSETS+=("$optional")
done

if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Candidate release $TAG already exists; uploading/refreshing assets."
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$GITHUB_REPOSITORY" --clobber
else
  gh release create "$TAG" "${ASSETS[@]}" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$GITHUB_SHA" \
    --title "$RELEASE_NAME" \
    --notes-file "$NOTES" \
    --prerelease
fi

echo "tag=$TAG" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Candidate release published: $TAG"
