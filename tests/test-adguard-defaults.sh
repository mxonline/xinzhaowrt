#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
seed="$root/files/etc/uci-defaults/96-xinzhao-adguardhome-defaults"
[[ -x "$seed" || -f "$seed" ]] || { echo 'FAIL: AdGuard Home first-boot YAML seed is missing.' >&2; exit 1; }
grep -Fq "address: 0.0.0.0:3000" "$seed" || { echo 'FAIL: AdGuard Home Web UI seed must use port 3000.' >&2; exit 1; }
grep -Fq "port: 5353" "$seed" || { echo 'FAIL: AdGuard Home seed must not take dnsmasq port 53.' >&2; exit 1; }
config="$root/files/etc/config/adguardhome"
grep -Eq "^[[:space:]]*option enabled '0'[[:space:]]*$" "$config" || { echo 'FAIL: AdGuard Home must remain disabled by default for DNS safety.' >&2; exit 1; }
echo 'PASS: AdGuard Home first-boot YAML seed preserves DNS compatibility.'
