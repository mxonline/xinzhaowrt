#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CONF="$PROJECT_ROOT/files/etc/nginx/conf.d/zz-xinzhao-upload.conf"
CGI_PATCH="$PROJECT_ROOT/patches/cgi-io/950-xinzhao-disk-upload-temp.patch"

[[ -f "$NGINX_CONF" ]] || { echo "ERROR: Nginx upload temp override missing"; exit 1; }
[[ -f "$PROJECT_ROOT/files/root/.xinzhao-upload/nginx/.keep" ]] || { echo "ERROR: Nginx disk temp directory is not provisioned"; exit 1; }
[[ -f "$PROJECT_ROOT/files/root/.xinzhao-upload/cgi-io/.keep" ]] || { echo "ERROR: cgi-io disk temp directory is not provisioned"; exit 1; }
[[ -f "$CGI_PATCH" ]] || { echo "ERROR: cgi-io upload temp patch missing"; exit 1; }

grep -Fq 'client_body_temp_path /root/.xinzhao-upload/nginx 1 2;' "$NGINX_CONF" || {
  echo "ERROR: Nginx request body temp path is not disk-backed"
  exit 1
}
grep -Fq 'XINZHAO_UPLOAD_TMPDIR "/root/.xinzhao-upload/cgi-io"' "$CGI_PATCH" || {
  echo "ERROR: cgi-io temp path is not disk-backed"
  exit 1
}
grep -Fq 'st.tempfd = open(XINZHAO_UPLOAD_TMPDIR' "$CGI_PATCH" || {
  echo "ERROR: cgi-io patch does not replace /tmp O_TMPFILE"
  exit 1
}

if grep -Fq 'client_body_temp_path /tmp' "$NGINX_CONF"; then
  echo "ERROR: Nginx upload path regressed to tmpfs"
  exit 1
fi

if grep -Fq 'st.tempfd = open("/tmp"' "$CGI_PATCH"; then
  echo "ERROR: cgi-io upload path regressed to tmpfs"
  exit 1
fi

echo 'PASS: large-upload OOM static guard is active and keeps transient upload copies off /tmp.'
