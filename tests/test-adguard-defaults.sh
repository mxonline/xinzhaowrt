#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/files/etc/config/adguardhome"
[[ -f "$config" ]] || { echo 'FAIL: AdGuard Home default UCI is missing.' >&2; exit 1; }
grep -Fq "option enabled '1'" "$config" || { echo 'FAIL: AdGuard Home Web UI must be enabled by default.' >&2; exit 1; }
grep -Fq "option config_file '/etc/adguardhome/adguardhome.yaml'" "$config" || { echo 'FAIL: AdGuard Home config path is not isolated.' >&2; exit 1; }
echo 'PASS: AdGuard Home default UCI enables the Web UI without changing DNS ownership.'
