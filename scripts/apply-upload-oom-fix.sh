#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: apply-upload-oom-fix.sh <immortalwrt-source-dir>}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CGI_PKG="$SRC/feeds/packages/net/cgi-io"
LUCI_FLASH="$SRC/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js"
LUCI_ACL="$SRC/feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"
PATCH_SRC="$PROJECT_ROOT/patches/cgi-io/950-xinzhao-disk-upload-temp.patch"
PATCH_DST="$CGI_PKG/patches/950-xinzhao-disk-upload-temp.patch"

[[ -d "$CGI_PKG" ]] || { echo "ERROR: cgi-io package source missing: $CGI_PKG"; exit 1; }
[[ -f "$LUCI_FLASH" ]] || { echo "ERROR: LuCI flash.js missing: $LUCI_FLASH"; exit 1; }
[[ -f "$LUCI_ACL" ]] || { echo "ERROR: LuCI flash ACL missing: $LUCI_ACL"; exit 1; }
[[ -f "$PATCH_SRC" ]] || { echo "ERROR: cgi-io OOM patch missing: $PATCH_SRC"; exit 1; }

# Keep OpenWrt's standard /tmp/firmware.bin handoff intact. sysupgrade expects the
# final image in tmpfs during the RAM-root upgrade stage. We only move transient
# HTTP/CGI upload buffering off tmpfs so the router never holds duplicate large
# upload copies in RAM.
grep -Fq "ui.uploadFile('/tmp/firmware.bin'" "$LUCI_FLASH" || {
  echo "ERROR: upstream LuCI firmware handoff changed; refusing unsafe path rewrite"
  exit 1
}
grep -Fq '"/tmp/firmware.bin": [ "write" ]' "$LUCI_ACL" || {
  echo "ERROR: upstream LuCI flash ACL no longer grants /tmp/firmware.bin"
  exit 1
}

mkdir -p "$(dirname "$PATCH_DST")"
cp "$PATCH_SRC" "$PATCH_DST"

grep -Fq 'XINZHAO_UPLOAD_TMPDIR "/root/.xinzhao-upload/cgi-io"' "$PATCH_DST"
grep -Fq 'st.tempfd = open(XINZHAO_UPLOAD_TMPDIR' "$PATCH_DST"

echo 'PASS: Arthur large-upload OOM fix staged; transient Nginx/cgi-io buffering is disk-backed while final sysupgrade handoff remains /tmp/firmware.bin.'
