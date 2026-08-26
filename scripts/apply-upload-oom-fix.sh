#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: apply-upload-oom-fix.sh <immortalwrt-source-dir>}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CGI_PKG="$SRC/feeds/packages/net/cgi-io"
LUCI_FLASH="$SRC/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js"
LUCI_ACL="$SRC/feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"
PATCH_DST="$CGI_PKG/patches/950-xinzhao-disk-upload-temp.patch"

[[ -d "$CGI_PKG" ]] || { echo "ERROR: cgi-io package source missing: $CGI_PKG"; exit 1; }
[[ -f "$LUCI_FLASH" ]] || { echo "ERROR: LuCI flash.js missing: $LUCI_FLASH"; exit 1; }
[[ -f "$LUCI_ACL" ]] || { echo "ERROR: LuCI flash ACL missing: $LUCI_ACL"; exit 1; }

# Keep OpenWrt's standard cgi-io O_TMPFILE and final LuCI firmware handoff on the
# same /tmp tmpfs. This is intentional: cgi-io can then linkat() its anonymous
# O_TMPFILE directly to /tmp/firmware.bin without a second 90+ MiB copy.
# Only Nginx request-body buffering is moved to disk by the files overlay.
grep -Fq "ui.uploadFile('/tmp/firmware.bin'" "$LUCI_FLASH" || {
  echo "ERROR: upstream LuCI firmware handoff changed; refusing unsafe path rewrite"
  exit 1
}
grep -Fq '"/tmp/firmware.bin": [ "write" ]' "$LUCI_ACL" || {
  echo "ERROR: upstream LuCI flash ACL no longer grants /tmp/firmware.bin"
  exit 1
}

# A reused source tree must never retain the rejected v0.1.1 cgi-io disk-temp patch.
rm -f "$PATCH_DST"

echo 'PASS: Arthur large-upload OOM fix staged; Nginx request bodies are disk-backed while cgi-io and final /tmp/firmware.bin remain on the same tmpfs for zero-copy linkat handoff.'
