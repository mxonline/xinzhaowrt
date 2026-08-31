#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_script="$root/scripts/add-custom-packages.sh"
web_defaults="$root/files/etc/uci-defaults/98-xinzhao-web-stack"

fail() {
  echo "QUICKSTART_WEB_SOURCE_GATE: FAIL -- $*" >&2
  exit 1
}

grep -Fq 'nas-packages-luci.git' "$source_script" || fail 'QuickStart LuCI source is not the official iStoreOS repository'
grep -Fq 'nas-packages.git' "$source_script" || fail 'QuickStart service source is not the official iStoreOS repository'
grep -Fq 'ISTORE_QUICKSTART_LUCI_REF' "$source_script" || fail 'QuickStart LuCI revision is not pinned'
grep -Fq 'ISTORE_QUICKSTART_REF' "$source_script" || fail 'QuickStart service revision is not pinned'
grep -Fq 'quickstart.$(PKG_ARCH_quickstart)' "$source_script" || fail 'QuickStart does not select the target-architecture artifact'
! grep -Fq 'quickstart.arm' "$source_script" || fail 'QuickStart still forces a 32-bit ARM artifact'
grep -Fq 'CONFIG_PACKAGE_luci-nginx=y' "$root/config/arthur.config" || fail 'nginx LuCI stack is not enabled'
[[ -f "$web_defaults" ]] || fail 'web-stack defaults are missing'
grep -Fq '/etc/init.d/uhttpd disable' "$web_defaults" || fail 'uhttpd is not disabled'
grep -Fq '/etc/init.d/uhttpd stop' "$web_defaults" || fail 'uhttpd is not stopped before nginx port use'
grep -Fq 'client_body_temp_path ' "$root/files/etc/nginx/conf.d/zz-xinzhao-upload.conf" || fail 'nginx overlay is missing'

echo 'QUICKSTART_WEB_SOURCE_GATE: PASS'
