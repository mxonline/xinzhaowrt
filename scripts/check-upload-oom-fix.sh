#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CONF="$PROJECT_ROOT/files/etc/nginx/conf.d/zz-xinzhao-upload.conf"
CGI_PATCH="$PROJECT_ROOT/patches/cgi-io/950-xinzhao-disk-upload-temp.patch"
CGI_DISK_DIR="$PROJECT_ROOT/files/root/.xinzhao-upload/cgi-io/.keep"
APPLY_SCRIPT="$PROJECT_ROOT/scripts/apply-upload-oom-fix.sh"

[[ -f "$NGINX_CONF" ]] || { echo "ERROR: Nginx upload temp override missing"; exit 1; }
[[ -f "$PROJECT_ROOT/files/root/.xinzhao-upload/nginx/.keep" ]] || { echo "ERROR: Nginx disk temp directory is not provisioned"; exit 1; }
[[ ! -e "$CGI_DISK_DIR" ]] || { echo "ERROR: rejected v0.1.1 cgi-io disk temp directory is still provisioned"; exit 1; }
[[ ! -e "$CGI_PATCH" ]] || { echo "ERROR: rejected v0.1.1 cgi-io disk-temp patch is still present"; exit 1; }

grep -Fq 'client_body_temp_path /root/.xinzhao-upload/nginx 1 2;' "$NGINX_CONF" || {
  echo "ERROR: Nginx request body temp path is not disk-backed"
  exit 1
}

if grep -Fq 'client_body_temp_path /tmp' "$NGINX_CONF"; then
  echo "ERROR: Nginx request body buffering regressed to tmpfs"
  exit 1
fi

grep -Fq 'rm -f "$PATCH_DST"' "$APPLY_SCRIPT" || {
  echo "ERROR: reused source trees are not protected from the rejected cgi-io disk-temp patch"
  exit 1
}

grep -Fq "ui.uploadFile('/tmp/firmware.bin'" "$APPLY_SCRIPT" || {
  echo "ERROR: LuCI final firmware handoff is not guarded as /tmp/firmware.bin"
  exit 1
}

echo 'PASS: large-upload OOM static guard uses disk-backed Nginx buffering and preserves cgi-io plus final firmware on the same /tmp tmpfs for linkat handoff.'
