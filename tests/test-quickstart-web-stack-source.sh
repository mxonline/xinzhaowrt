#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mature_sources="$root/production/mature-ui-sources.json"
luci_defaults="$root/files/etc/uci-defaults/97-xinzhao-luci-defaults"

fail() {
  echo "QUICKSTART_WEB_SOURCE_GATE: FAIL -- $*" >&2
  exit 1
}

[[ -s "$mature_sources" ]] || fail 'mature UI source lock is missing'
grep -Fq 'https://github.com/linkease/nas-packages-luci.git' "$mature_sources" || fail 'QuickStart preview source is not the official iStoreOS repository'
grep -Fq '7e5083e2ca4cfa4d31f312026f46e5213c5b03f5' "$mature_sources" || fail 'QuickStart preview source revision is not pinned'
grep -Fq '"subdir": "luci/luci-app-quickstart"' "$mature_sources" || fail 'QuickStart mature package path is not pinned'
grep -Fq 'CONFIG_PACKAGE_luci-nginx=y' "$root/config/arthur.config" || fail 'nginx LuCI stack is not enabled'
grep -Fq "homepage='admin/quickstart'" "$luci_defaults" || fail 'LuCI homepage is not set to QuickStart'
grep -Fq 'cgi-bin/luci/admin/quickstart' "$root/scripts/real-device-verify.ps1" || fail 'real-device verification does not exercise the QuickStart route'
grep -Fq 'luci-static/quickstart/index.js' "$root/scripts/real-device-verify.ps1" || fail 'real-device verification does not require rendered QuickStart assets'

echo 'QUICKSTART_WEB_SOURCE_GATE: PASS'
