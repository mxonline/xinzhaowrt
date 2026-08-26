#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: verify-upload-oom-build.sh <immortalwrt-source-dir>}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROJECT_ROOT/output/upload-oom-verification.txt"
NGINX_CONF="$SRC/files/etc/nginx/conf.d/zz-xinzhao-upload.conf"
LUCI_FLASH="$SRC/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js"
LUCI_ACL="$SRC/feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"

mkdir -p "$(dirname "$OUT")"
: > "$OUT"

pass() {
  echo "PASS: $*" | tee -a "$OUT"
}

fail() {
  echo "FAIL: $*" | tee -a "$OUT" >&2
  exit 1
}

[[ -f "$NGINX_CONF" ]] || fail "final files overlay is missing Nginx large-upload override"
grep -Fq 'client_body_temp_path /root/.xinzhao-upload/nginx 1 2;' "$NGINX_CONF" || fail "Nginx request body temp path is not disk-backed"
[[ -f "$SRC/files/root/.xinzhao-upload/nginx/.keep" ]] || fail "Nginx disk upload directory missing from final files overlay"
[[ -f "$SRC/files/root/.xinzhao-upload/cgi-io/.keep" ]] || fail "cgi-io disk upload directory missing from final files overlay"
pass "Nginx large request bodies are buffered outside /tmp tmpfs."

CGI_SOURCE="$(find "$SRC/build_dir" -type f -path '*/cgi-io-*/main.c' -print -quit 2>/dev/null || true)"
[[ -n "$CGI_SOURCE" && -f "$CGI_SOURCE" ]] || fail "compiled cgi-io source tree was not found"
grep -Fq '#define XINZHAO_UPLOAD_TMPDIR "/root/.xinzhao-upload/cgi-io"' "$CGI_SOURCE" || fail "cgi-io source patch was not applied"
grep -Fq 'st.tempfd = open(XINZHAO_UPLOAD_TMPDIR' "$CGI_SOURCE" || fail "cgi-io still opens upload O_TMPFILE in /tmp"
pass "cgi-io transient upload O_TMPFILE is disk-backed in the compiled source tree."

[[ -f "$LUCI_FLASH" ]] || fail "LuCI flash.js missing"
[[ -f "$LUCI_ACL" ]] || fail "LuCI flash ACL missing"
grep -Fq "ui.uploadFile('/tmp/firmware.bin'" "$LUCI_FLASH" || fail "LuCI final firmware handoff no longer uses /tmp/firmware.bin"
grep -Fq '"/tmp/firmware.bin": [ "write" ]' "$LUCI_ACL" || fail "LuCI ACL no longer authorizes the standard /tmp/firmware.bin handoff"
pass "LuCI final firmware handoff remains /tmp/firmware.bin for standard sysupgrade RAM-root semantics."

pass "Arthur large-upload OOM guard verified: transient duplicate upload copies are kept off tmpfs while the final sysupgrade image remains in /tmp."
