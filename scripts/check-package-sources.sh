#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
FEED_DIR="$SRC/package/feeds/xinzhao"

required=(
  luci-app-istorex
  luci-app-lucky
  luci-app-quickfile
  luci-app-quickstart
  luci-app-store
  luci-app-diskman
  luci-app-easytier
  easytier
  luci-app-mosdns
  mosdns
  v2dat
  v2ray-geodata
  luci-app-openclash
  luci-app-oaf
  oaf
  open-app-filter
)

missing=0
for pkg in "${required[@]}"; do
  path="$FEED_DIR/$pkg"
  if [[ ! -e "$path" || ! -f "$path/Makefile" ]]; then
    echo "MISSING_SOURCE: $pkg ($path)"
    missing=1
  fi
done

if (( missing )); then
  echo "ERROR: one or more selected external package sources are not installed correctly."
  exit 1
fi

echo "PASS: selected external package sources are installed through feed xinzhao."
