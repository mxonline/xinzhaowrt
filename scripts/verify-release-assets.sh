#!/usr/bin/env bash
set -Eeuo pipefail

DIR="${1:-output/firmware}"
mapfile -t files < <(find "$DIR" -maxdepth 1 -type f -name '*jdcloud_re-ss-01*.bin' -size +0c | sort)
(( ${#files[@]} > 0 )) || {
  echo "ERROR: no non-empty jdcloud_re-ss-01 firmware in $DIR"
  exit 1
}
for file in "${files[@]}"; do
  echo "$(basename "$file") $(stat -c%s "$file") bytes $(sha256sum "$file" | awk '{print $1}')"
done
