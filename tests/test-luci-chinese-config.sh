#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-config.sh"
VERIFY="$ROOT/scripts/verify-built-plugins.sh"
CONFIG="$ROOT/config/arthur.config"

grep -qxF 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y' "$CONFIG" || {
  echo 'FAIL: Arthur config must request the standard LuCI Simplified Chinese package' >&2
  exit 1
}

grep -qF 'CONFIG_PACKAGE_luci-i18n-base-zh-cn=y' "$CHECKER" || {
  echo 'FAIL: check-config must enforce the standard LuCI Simplified Chinese package' >&2
  exit 1
}

grep -qF 'luci-i18n-base-zh-cn' "$CHECKER" || {
  echo 'FAIL: check-config must report a missing LuCI Chinese package explicitly' >&2
  exit 1
}

grep -qF 'luci-i18n-base-zh-cn' "$VERIFY" || {
  echo 'FAIL: final firmware verification must require the compiled LuCI Chinese package' >&2
  exit 1
}

grep -qF 'base.zh-cn.lmo' "$VERIFY" || {
  echo 'FAIL: final firmware verification must require the base.zh-cn.lmo translation resource' >&2
  exit 1
}

echo 'LUCI_CHINESE_CONFIG_CONTRACT=PASS'
