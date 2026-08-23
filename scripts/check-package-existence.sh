#!/usr/bin/env bash
set -euo pipefail

# 在 make defconfig 前确认必需 package 已由正确 feed 注册且存在 Makefile。
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
REQUIRED_FILE="$PROJECT_ROOT/config/required-plugins.txt"
FAILED=0
MISSING_PACKAGES=()
MISSING_FEEDS=()

report_missing_feed() {
  local feed="$1" path="$SRC/package/feeds/$1"
  echo "MISSING_FEED: feed=$feed path=$path"
  MISSING_FEEDS+=("$feed|$path")
  FAILED=1
}

report_missing_package() {
  local pkg="$1" feed="$2" path="$3"
  echo "MISSING_PACKAGE: package=$pkg feed=$feed path=$path"
  MISSING_PACKAGES+=("$pkg|$feed|$path")
  FAILED=1
}

[[ -d "$SRC/package/feeds/istore" ]] || report_missing_feed istore
[[ -d "$SRC/package/feeds/xinzhao" ]] || report_missing_feed xinzhao

is_xinzhao_package() {
  case "$1" in
    luci-app-istorex|luci-app-lucky|lucky|luci-app-quickfile|quickfile|\
    luci-app-quickstart|quickstart|luci-app-diskman|luci-app-easytier|easytier|\
    luci-app-mosdns|mosdns|v2dat|v2ray-geodata|luci-app-openclash|\
    luci-app-oaf|oaf|open-app-filter|luci-app-adguardhome|luci-app-autoreboot|\
    luci-app-firewall|luci-app-package-manager|luci-app-pbr|luci-app-samba4|\
    luci-app-smartdns|luci-app-sqm|\
    luci-app-ttyd|luci-app-upnp|luci-app-vlmcsd|luci-app-wol|smartdns|\
    sqm-scripts|ttyd|miniupnpd|vlmcsd|etherwake) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  if [[ "$pkg" == "luci-app-store" ]]; then
    path="$SRC/package/feeds/istore/$pkg"
    if [[ ! -f "$path/Makefile" ]]; then
      report_missing_package "$pkg" istore "$path/Makefile"
    else
      echo "FOUND_PACKAGE: package=$pkg feed=istore path=$path/Makefile"
    fi
  elif is_xinzhao_package "$pkg"; then
    path="$SRC/package/feeds/xinzhao/$pkg"
    if [[ ! -f "$path/Makefile" ]]; then
      report_missing_package "$pkg" xinzhao "$path/Makefile"
    else
      echo "FOUND_PACKAGE: package=$pkg feed=xinzhao path=$path/Makefile"
    fi
  else
    path="$(find "$SRC/package/feeds" -type f -path "*/$pkg/Makefile" -print -quit 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
      report_missing_package "$pkg" 'packages|luci|routing' \
        "$SRC/package/feeds/{packages,luci,routing}/$pkg/Makefile"
    else
      feed_path="${path#"$SRC/package/feeds/"}"
      feed_name="${feed_path%%/*}"
      echo "FOUND_PACKAGE: package=$pkg feed=$feed_name path=$path"
    fi
  fi
done < "$REQUIRED_FILE"

if grep -Eq '^[[:space:]]*luci-app-istore([[:space:]]|$)' "$REQUIRED_FILE"; then
  echo "INVALID_PACKAGE: luci-app-istore; use luci-app-store from feed istore"
  FAILED=1
fi

if (( FAILED )); then
  echo
  echo "ERROR: required package existence check failed before make defconfig."
  echo "MISSING_PACKAGE_COUNT: ${#MISSING_PACKAGES[@]}"
  for item in "${MISSING_PACKAGES[@]}"; do
    IFS='|' read -r pkg feed path <<< "$item"
    echo "  - package=$pkg feed=$feed path=$path"
  done
  echo "MISSING_FEED_COUNT: ${#MISSING_FEEDS[@]}"
  for item in "${MISSING_FEEDS[@]}"; do
    IFS='|' read -r feed path <<< "$item"
    echo "  - feed=$feed path=$path"
  done
  exit 1
fi
echo "PASS: all required package Makefiles exist before make defconfig."
