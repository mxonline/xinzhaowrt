#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/files/etc/config/nginx"
defaults="$root/files/etc/uci-defaults/98-xinzhao-web-stack"

fail() {
  echo "ARTHUR_WEB_HTTP_CONTRACT: FAIL -- $*" >&2
  exit 1
}

[[ -f "$config" ]] || fail 'Nginx HTTP-only UCI baseline is missing from the rootfs overlay'
grep -Eq "^[[:space:]]*config main 'global'[[:space:]]*$" "$config" || fail 'Nginx global section is missing'
grep -Eq "^[[:space:]]*list listen '0\.0\.0\.0:80'[[:space:]]*$" "$config" || fail 'IPv4 HTTP/80 listener is not the source baseline'
grep -Eq "^[[:space:]]*list listen '\[::\]:80'[[:space:]]*$" "$config" || fail 'IPv6 HTTP/80 listener is not the source baseline'
! grep -Eq '(^|[^0-9])443([^0-9]|$)|ssl|_redirect2ssl|https://\$host' "$config" || fail 'Nginx source baseline still enables HTTPS/443 or HTTP redirect'

grep -Fq 'uci -q delete nginx._redirect2ssl' "$defaults" || fail 'runtime reconcile does not remove the redirect server'
grep -Fq "uci -q add_list nginx._lan.listen='0.0.0.0:80'" "$defaults" || fail 'runtime reconcile does not enforce IPv4 HTTP/80'
grep -Fq "uci -q add_list nginx._lan.listen='[::]:80'" "$defaults" || fail 'runtime reconcile does not enforce IPv6 HTTP/80'

echo 'ARTHUR_WEB_HTTP_CONTRACT: PASS'
