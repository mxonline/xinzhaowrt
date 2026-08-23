#!/usr/bin/env bash
set -euo pipefail

# 在 make defconfig 前确认必需 package 已由正确 feed 注册且存在 Makefile。
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
REQUIRED_FILE="$PROJECT_ROOT/config/required-plugins.txt"
FAILED=0

[[ -d "$SRC/package/feeds/istore" ]] || { echo "MISSING_FEED: istore"; FAILED=1; }
[[ -d "$SRC/package/feeds/xinzhao" ]] || { echo "MISSING_FEED: xinzhao"; FAILED=1; }

is_xinzhao_package() {
  case "$1" in
    luci-app-istorex|luci-app-lucky|lucky|luci-app-quickfile|quickfile|\
    luci-app-quickstart|quickstart|luci-app-diskman|luci-app-easytier|easytier|\
    luci-app-mosdns|mosdns|v2dat|v2ray-geodata|luci-app-openclash|\
    luci-app-oaf|oaf|open-app-filter|luci-app-smartdns|luci-app-sqm|\
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
      echo "MISSING_PACKAGE: $pkg (feed=istore path=$path)"
      FAILED=1
    else
      echo "FOUND_PACKAGE: $pkg (feed=istore)"
    fi
  elif is_xinzhao_package "$pkg"; then
    path="$SRC/package/feeds/xinzhao/$pkg"
    if [[ ! -f "$path/Makefile" ]]; then
      echo "MISSING_PACKAGE: $pkg (feed=xinzhao path=$path)"
      FAILED=1
    else
      echo "FOUND_PACKAGE: $pkg (feed=xinzhao)"
    fi
  else
    path="$(find "$SRC/package/feeds" -type f -path "*/$pkg/Makefile" -print -quit 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
      echo "MISSING_PACKAGE: $pkg (any standard feed)"
      FAILED=1
    else
      echo "FOUND_PACKAGE: $pkg (standard feed: ${path#"$SRC/package/feeds/"})"
    fi
  fi
done < "$REQUIRED_FILE"

if grep -Eq '^[[:space:]]*luci-app-istore([[:space:]]|$)' "$REQUIRED_FILE"; then
  echo "INVALID_PACKAGE: luci-app-istore; use luci-app-store from feed istore"
  FAILED=1
fi

# 明确核对六个此前缺失的 LuCI 包，避免检查逻辑退回到模糊的 any-feed 搜索。
for pkg in luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol; do
  path="$SRC/package/feeds/xinzhao/$pkg/Makefile"
  if [[ ! -f "$path" ]]; then
    echo "MISSING_PACKAGE: $pkg (feed=xinzhao path=$path)"
    FAILED=1
  else
    echo "FOUND_PACKAGE: $pkg (feed=xinzhao, source=$(readlink -f "$SRC/package/feeds/xinzhao/$pkg"))"
  fi
done

if (( FAILED )); then
  echo "ERROR: required package existence check failed before make defconfig."
  exit 1
fi
echo "PASS: all required package Makefiles exist before make defconfig."
