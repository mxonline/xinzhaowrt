#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="$root/files/etc/uci-defaults/99-xinzhao-defaults"
wifi_defaults="$root/files/etc/uci-defaults/98-xinzhao-wifi-defaults"

[[ -f "$wifi_defaults" ]] || {
  echo 'FAIL: Wi-Fi defaults must run independently of the general first-boot marker.' >&2
  exit 1
}
grep -Fq "wifi_default_password='12356789'" "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi migration defaults must define the locked password.' >&2
  exit 1
}
grep -Fq 'uci commit wireless' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi migration defaults must commit persistent UCI.' >&2
  exit 1
}
grep -Fq 'wifi config' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi defaults must generate radio config when first-boot UCI is absent.' >&2
  exit 1
}
grep -Fq 'XinZhaoWrt-5G' "$wifi_defaults" || {
  echo 'FAIL: 5 GHz default SSID is not configured.' >&2
  exit 1
}
grep -Fq 'XinZhaoWrt-2.4G' "$wifi_defaults" || {
  echo 'FAIL: 2.4 GHz default SSID is not configured.' >&2
  exit 1
}

grep -Fq "wifi_default_password='12356789'" "$defaults" || {
  echo 'FAIL: first-boot defaults must define the locked default Wi-Fi password.' >&2
  exit 1
}
grep -Fq 'wireless.$wifi_section.key=$wifi_default_password' "$defaults" || {
  echo 'FAIL: first-boot defaults must apply the password to each Wi-Fi interface.' >&2
  exit 1
}
grep -Fq 'XinZhaoWrt-5G' "$defaults" || {
  echo 'FAIL: first-boot defaults must configure the 5 GHz SSID.' >&2
  exit 1
}
grep -Fq 'XinZhaoWrt-2.4G' "$defaults" || {
  echo 'FAIL: first-boot defaults must configure the 2.4 GHz SSID.' >&2
  exit 1
}
grep -Fq 'uci commit wireless' "$defaults" || {
  echo 'FAIL: Wi-Fi defaults must be committed to persistent UCI configuration.' >&2
  exit 1
}

echo 'PASS: first-boot defaults configure the unified Wi-Fi password.'
