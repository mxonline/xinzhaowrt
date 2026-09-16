#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?usage: $0 <sysupgrade.bin> <unsquashfs>}"
UNSQUASHFS="${2:?usage: $0 <sysupgrade.bin> <unsquashfs>}"
[[ -s "$IMAGE" ]] || { echo "ERROR: missing firmware image: $IMAGE" >&2; exit 1; }
if [[ ! -x "$UNSQUASHFS" ]]; then
  UNSQUASHFS="$(command -v unsquashfs || true)"
fi
[[ -n "$UNSQUASHFS" && -x "$UNSQUASHFS" ]] || { echo 'ERROR: missing unsquashfs verifier dependency' >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo 'ERROR: missing readelf verifier dependency' >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
member="$(tar -tf "$IMAGE" | awk '/\/root$/ { print; exit }')"
[[ -n "$member" ]] || { echo 'ERROR: sysupgrade image has no rootfs member' >&2; exit 1; }
tar -xOf "$IMAGE" "$member" > "$tmp/root.squashfs"

# Do not fully extract SquashFS here. GitHub-hosted runners are unprivileged and
# an OpenWrt rootfs contains device nodes such as /dev/console; a normal
# `unsquashfs -d` therefore fails even when the firmware itself is valid. Read
# only the regular files and metadata needed by this gate.
has_file() {
  local rel="$1"
  "$UNSQUASHFS" -cat "$tmp/root.squashfs" "$rel" >/dev/null 2>&1
}

require_file() {
  local rel="$1"
  has_file "$rel" || { echo "ERROR: final rootfs missing $rel" >&2; exit 1; }
}

extract_file() {
  local rel="$1"
  local out="$2"
  "$UNSQUASHFS" -cat "$tmp/root.squashfs" "$rel" > "$out" 2>/dev/null || {
    echo "ERROR: unable to read final rootfs file: $rel" >&2
    exit 1
  }
}

require_exec() {
  local rel="$1"
  local line perms
  require_file "$rel"
  line="$("$UNSQUASHFS" -ll "$tmp/root.squashfs" "$rel" 2>/dev/null | grep -F "squashfs-root/$rel" | head -n1 || true)"
  [[ -n "$line" ]] || { echo "ERROR: unable to read final rootfs metadata: $rel" >&2; exit 1; }
  perms="$(awk '{print $1}' <<<"$line")"
  [[ ${#perms} -ge 4 && "${perms:3:1}" == 'x' ]] || {
    echo "ERROR: final rootfs file is not executable: $rel ($perms)" >&2
    exit 1
  }
}

require_aarch64() {
  local rel="$1"
  local out="$tmp/$(basename "$rel").bin"
  require_exec "$rel"
  extract_file "$rel" "$out"
  readelf -h "$out" | grep -Eq 'Machine:[[:space:]]+AArch64' || {
    echo "ERROR: final rootfs binary is not AArch64: $rel" >&2
    exit 1
  }
}

read_text() {
  local rel="$1"
  local out="$2"
  require_file "$rel"
  extract_file "$rel" "$out"
}

# Complete OpenClash: LuCI package, lifecycle/runtime scripts, bundled Meta core,
# and a concrete architecture selection. Package presence alone is insufficient.
require_file 'usr/lib/lua/luci/controller/openclash.lua'
require_file 'usr/share/openclash/openclash_core.sh'
require_file 'etc/config/openclash'
require_aarch64 'etc/openclash/core/clash_meta'
openclash_config="$tmp/openclash.config"
read_text 'etc/config/openclash' "$openclash_config"
grep -Fq "option core_version 'linux-arm64'" "$openclash_config" || {
  echo 'ERROR: final OpenClash config does not select linux-arm64 core' >&2
  exit 1
}

echo 'OPENCLASH_CORE_BUNDLED=PASS'
echo 'OPENCLASH_CORE_ARCH=PASS'
echo 'OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED=PASS'

# Complete mature AdGuardHome manager and bundled daemon. These paths are the
# accepted pinned manager's user-visible menu/controller/CBI/lifecycle surface.
for rel in \
  'usr/lib/lua/luci/controller/AdGuardHome.lua' \
  'usr/lib/lua/luci/model/cbi/AdGuardHome/overview.lua' \
  'usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua' \
  'usr/lib/lua/luci/model/cbi/AdGuardHome/tools.lua' \
  'usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua' \
  'usr/lib/lua/luci/view/AdGuardHome/overview.htm' \
  'usr/share/luci/menu.d/luci-app-adguardhome.json' \
  'usr/share/rpcd/acl.d/luci-app-adguardhome.json' \
  'usr/share/AdGuardHome/AdGuardHome_template.yaml' \
  'etc/config/AdGuardHome'; do
  require_file "$rel"
done
require_exec 'etc/init.d/AdGuardHome'
require_aarch64 'usr/bin/AdGuardHome'

adh_config="$tmp/AdGuardHome.config"
read_text 'etc/config/AdGuardHome' "$adh_config"
grep -Eq "^[[:space:]]*option[[:space:]]+enabled[[:space:]]+'0'[[:space:]]*$" "$adh_config" || {
  echo 'ERROR: AdGuardHome mature manager is not disabled by default' >&2
  exit 1
}

# The binary dependency also ships its lowercase service. It must likewise be
# disabled by default so only the mature manager controls runtime activation.
if has_file 'etc/config/adguardhome'; then
  adh_lower_config="$tmp/adguardhome.config"
  extract_file 'etc/config/adguardhome' "$adh_lower_config"
  grep -Eq "^[[:space:]]*option[[:space:]]+enabled[[:space:]]+'?0'?[[:space:]]*$" "$adh_lower_config" || {
    echo 'ERROR: lower-case AdGuardHome dependency is not disabled by default' >&2
    exit 1
  }
fi

echo 'ADH_LUCI_FULL_MANAGER_ROOTFS=PASS'
echo 'ADH_BINARY_BUNDLED=PASS'
echo 'ADH_DEFAULT_STATE=DISABLED'
echo 'FULL_OPENCLASH_ADH_ROOTFS=PASS'
