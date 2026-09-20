#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "ARTHUR_SOURCE_PARITY: FAIL -- $*" >&2; exit 1; }
pass() { echo "$1=PASS"; }

COORD="$ROOT/files/usr/libexec/xinzhao-dns-coexist"
ADH_YAML="$ROOT/files/etc/AdGuardHome.yaml"
ADH_TEMPLATE="$ROOT/files/usr/share/AdGuardHome/AdGuardHome_template.yaml"
SWAP_DEFAULTS="$ROOT/files/etc/uci-defaults/98-xinzhao-native-swap"

grep -Fq 'waiting for lifecycle transition lock' "$COORD" || fail 'bounded lifecycle lock wait is missing'
grep -Fq 'acquired lifecycle transition lock after' "$COORD" || fail 'bounded lifecycle lock acquisition evidence is missing'
grep -Fq 'boot-reconcile' "$COORD" || fail 'reboot reconcile action is missing'
grep -Fq 'LAN:dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874' "$ROOT/production/ARTHUR_PRODUCT_TARGETS.md" || true
grep -Fq "option adguardhome_dns_port '1745'" "$ROOT/files/etc/config/xinzhao-dns" || fail 'AdGuardHome DNS port source is not 1745'
grep -Fq "option openclash_dns_port '7874'" "$ROOT/files/etc/config/xinzhao-dns" || fail 'OpenClash DNS port source is not 7874'
grep -Fq "option enabled '0'" "$ROOT/files/etc/config/AdGuardHome" || fail 'AdGuardHome source default is not disabled'
grep -Fq "option redirect 'none'" "$ROOT/files/etc/config/AdGuardHome" || fail 'AdGuardHome source redirect default is not none'
grep -Fq 'enable_redirect_dns 0' "$COORD" || fail 'OpenClash DNS redirect suppression is missing'
grep -Fq 'redirect_dns 0' "$COORD" || fail 'OpenClash DNS hijack suppression is missing'
grep -Fq "list listen '0.0.0.0:80'" "$ROOT/files/etc/config/nginx" || fail 'HTTP/80 source listener is missing'
grep -Fq "list listen '[::]:80'" "$ROOT/files/etc/config/nginx" || fail 'IPv6 HTTP/80 source listener is missing'
! grep -Eq '(^|[^0-9])443([^0-9]|$)|ssl|_redirect2ssl' "$ROOT/files/etc/config/nginx" || fail 'HTTPS/443 or redirect remains in source Nginx config'
grep -Fq 'AdGuardHome.AdGuardHome.enabled' "$ROOT/scripts/real-device-verify.ps1" || fail 'device verifier uses the wrong AdGuardHome UCI namespace'
! grep -Fq 'uci -q get adguardhome.config.enabled' "$ROOT/scripts/real-device-verify.ps1" || fail 'device verifier trusts the non-authoritative namespace'

test -x "$SWAP_DEFAULTS" || fail 'native swap first-boot source is missing'
grep -Fq '/dev/mmcblk0p28' "$SWAP_DEFAULTS" || fail 'Arthur native swap device is missing'
grep -Fq 'TYPE="swap"' "$SWAP_DEFAULTS" || fail 'swap type guard is missing'
grep -Fq 'uci -q add fstab swap' "$SWAP_DEFAULTS" || fail 'idempotent fstab swap creation is missing'
grep -Fq 'enabled=1' "$SWAP_DEFAULTS" || fail 'native swap is not enabled in source'

for yaml in "$ADH_YAML" "$ADH_TEMPLATE"; do
  test -s "$yaml" || fail "missing AdGuardHome YAML source: $yaml"
  ! grep -Fq 'edns_client_subnet: false' "$yaml" || fail "legacy EDNS scalar remains: $yaml"
  ! grep -Eq '^[[:space:]]*clients:[[:space:]]*\[\]' "$yaml" || fail "legacy clients list remains: $yaml"
  grep -Fq 'runtime_sources:' "$yaml" || fail "compatible clients mapping missing: $yaml"
  grep -Fq 'custom_ip: ""' "$yaml" || fail "compatible EDNS mapping missing: $yaml"
done

pass ARTHUR_SOURCE_PARITY
