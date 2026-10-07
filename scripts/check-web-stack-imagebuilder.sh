#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/arthur-fast-candidate.yml"
OVERLAY="$ROOT/files/etc/uci-defaults/98-xinzhao-web-stack"
NGINX_CONFIG="$ROOT/files/etc/config/nginx"
UHTTPD_INIT="$ROOT/files/etc/init.d/uhttpd"

grep -qF -- '-uhttpd' "$WORKFLOW" || { echo 'ERROR: ImageBuilder does not remove uhttpd'; exit 1; }
grep -qF -- '-uhttpd-mod-ubus' "$WORKFLOW" || { echo 'ERROR: ImageBuilder does not remove uhttpd-mod-ubus'; exit 1; }
grep -qF 'XINZHAO_NGINX_PRIMARY=1' "$UHTTPD_INIT" || { echo 'ERROR: uhttpd init guard is not a Nginx no-op'; exit 1; }
grep -qF 'XINZHAO_NGINX_PRIMARY=1' "$WORKFLOW" || { echo 'ERROR: runtime gate does not verify the uhttpd init guard'; exit 1; }
grep -qF '/etc/init.d/nginx restart' "$OVERLAY" || { echo 'ERROR: Nginx restart guard missing'; exit 1; }
grep -qF '/etc/init.d/uhttpd disable' "$OVERLAY" || { echo 'ERROR: defensive uhttpd disable missing'; exit 1; }
grep -qF "uci -q add_list nginx._lan.listen='0.0.0.0:80'" "$OVERLAY" || { echo 'ERROR: public HTTP/80 listener is not enforced'; exit 1; }
grep -qF 'uci -q delete nginx._redirect2ssl' "$OVERLAY" || { echo 'ERROR: HTTP-to-HTTPS redirect is not removed'; exit 1; }
test -s "$NGINX_CONFIG" || { echo 'ERROR: HTTP-only Nginx UCI baseline is missing'; exit 1; }
grep -qF "list listen '0.0.0.0:80'" "$NGINX_CONFIG" || { echo 'ERROR: source Nginx IPv4 HTTP/80 listener is missing'; exit 1; }
grep -qF "list listen '[::]:80'" "$NGINX_CONFIG" || { echo 'ERROR: source Nginx IPv6 HTTP/80 listener is missing'; exit 1; }
! grep -Eq '(^|[^0-9])443([^0-9]|$)|ssl|_redirect2ssl|https://\$host' "$NGINX_CONFIG" || { echo 'ERROR: source Nginx baseline enables HTTPS/443 or redirect'; exit 1; }

echo 'WEB_STACK_IMAGEBUILDER_STATIC_CHECK: PASS'
