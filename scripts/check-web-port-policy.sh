#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/files/etc/uci-defaults/98-xinzhao-web-stack"

[[ -f "$POLICY" ]] || { echo "ERROR: missing HTTP-only web policy: $POLICY" >&2; exit 1; }
bash -n "$POLICY"

grep -Fq "uci -q delete nginx._lan" "$POLICY" || { echo 'ERROR: HTTP-only policy does not rebuild nginx._lan' >&2; exit 1; }
grep -Fq "uci set nginx._lan='server'" "$POLICY" || { echo 'ERROR: HTTP-only policy does not recreate nginx._lan server' >&2; exit 1; }
grep -Fq "uci add_list nginx._lan.listen='80 default_server'" "$POLICY" || { echo 'ERROR: IPv4 port 80 listener missing' >&2; exit 1; }
grep -Fq "uci add_list nginx._lan.listen='[::]:80 default_server'" "$POLICY" || { echo 'ERROR: IPv6 port 80 listener missing' >&2; exit 1; }
grep -Fq "uci add_list nginx._lan.include='conf.d/*.locations'" "$POLICY" || { echo 'ERROR: LuCI/QuickFile location include missing' >&2; exit 1; }

if grep -Eq "listen=.*443|redirect2ssl|uci_manage_ssl|ssl_certificate|ssl_session" "$POLICY"; then
  echo 'ERROR: HTTP-only policy still contains HTTPS/SSL listener or redirect controls' >&2
  exit 1
fi

grep -Fq 'DEFAULT_ROOT_PASSWORD="password"' "$ROOT/build.env" || { echo 'ERROR: root password baseline is not password' >&2; exit 1; }

echo 'WEB_PORT_POLICY=PASS'
echo 'HTTP_80=ENABLED'
echo 'HTTPS_443=DISABLED'
echo 'HTTP_TO_HTTPS_REDIRECT=DISABLED'
