#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:?usage: $0 <.config>}"
VERSION_FILE="$PROJECT_ROOT/VERSION"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: missing config file: $CONFIG_FILE" >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "ERROR: missing VERSION file" >&2; exit 1; }

FIRMWARE_VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
[[ -n "$FIRMWARE_VERSION" ]] || { echo "ERROR: VERSION is empty" >&2; exit 1; }

set_config() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    $0 ~ "^" key "=" {
      if (!seen++) print value
      next
    }
    { print }
    END {
      if (!seen) print value
    }
  ' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# ImmortalWrt gates VERSIONOPT behind IMAGEOPT. Inject both so the build does
# not rely on the seed being the only caller of this script.
set_config CONFIG_IMAGEOPT 'CONFIG_IMAGEOPT=y'
set_config CONFIG_VERSIONOPT 'CONFIG_VERSIONOPT=y'
set_config CONFIG_VERSION_DIST 'CONFIG_VERSION_DIST="XinZhaoWrt"'
set_config CONFIG_VERSION_NUMBER "CONFIG_VERSION_NUMBER=\"$FIRMWARE_VERSION\""
set_config CONFIG_VERSION_MANUFACTURER 'CONFIG_VERSION_MANUFACTURER="XinZhao Network"'
set_config CONFIG_VERSION_PRODUCT 'CONFIG_VERSION_PRODUCT="JDCloud Arthur RE-SS-01"'

echo "PASS: injected XinZhaoWrt version identity v$FIRMWARE_VERSION from VERSION."
