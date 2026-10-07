#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/arthur.config"

grep -Fxq 'CONFIG_LUCI_LANG_zh_Hans=y' "$CONFIG" || {
  echo 'FAIL: Arthur config must enable the Simplified Chinese LuCI language symbol' >&2
  exit 1
}
grep -Fxq 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y' "$CONFIG" || {
  echo 'FAIL: Arthur config must request the base Simplified Chinese LuCI package' >&2
  exit 1
}

echo 'PASS: Arthur LuCI Simplified Chinese language configuration is enabled'
