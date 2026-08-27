#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CONF="$PROJECT_ROOT/files/etc/nginx/conf.d/zz-xinzhao-upload.conf"

[[ -f "$NGINX_CONF" ]] || { echo "ERROR: Nginx upload temp override missing"; exit 1; }
[[ -f "$PROJECT_ROOT/files/root/.xinzhao-upload/nginx/.keep" ]] || { echo "ERROR: Nginx disk temp directory is not provisioned"; exit 1; }

grep -Fq 'client_body_temp_path /root/.xinzhao-upload/nginx 1 2;' "$NGINX_CONF" || {
  echo "ERROR: Nginx request body temp path is not disk-backed"
  exit 1
}
if grep -Fq 'client_body_temp_path /tmp' "$NGINX_CONF"; then
  echo "ERROR: Nginx upload path regressed to tmpfs"
  exit 1
fi

if [[ -e "$PROJECT_ROOT/patches/cgi-io/950-xinzhao-disk-upload-temp.patch" || \
      -e "$PROJECT_ROOT/files/root/.xinzhao-upload/cgi-io/.keep" ]]; then
  echo "ERROR: custom cgi-io temp-directory override must not be restored"
  exit 1
fi

echo 'PASS: Nginx request buffering stays disk-backed and the official cgi-io implementation is not overridden.'
