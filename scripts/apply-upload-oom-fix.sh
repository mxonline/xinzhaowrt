#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: apply-upload-oom-fix.sh <immortalwrt-source-dir>}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CGI_PKG="$SRC/feeds/packages/net/cgi-io"
CGI_RECIPE="$CGI_PKG/Makefile"
LUCI_FLASH="$SRC/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js"
LUCI_ACL="$SRC/feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"

[[ -d "$CGI_PKG" ]] || { echo "ERROR: cgi-io package source missing: $CGI_PKG"; exit 1; }
[[ -f "$CGI_RECIPE" ]] || { echo "ERROR: cgi-io package recipe missing: $CGI_RECIPE"; exit 1; }
[[ -f "$LUCI_FLASH" ]] || { echo "ERROR: LuCI flash.js missing: $LUCI_FLASH"; exit 1; }
[[ -f "$LUCI_ACL" ]] || { echo "ERROR: LuCI flash ACL missing: $LUCI_ACL"; exit 1; }

"$PROJECT_ROOT/scripts/check-upload-oom-fix.sh"

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

echo 'PASS: pre-build upload guard retained cgi-io package recipe and LuCI /tmp/firmware.bin handoff.'
