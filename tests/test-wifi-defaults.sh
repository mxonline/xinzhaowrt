#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="$root/files/etc/uci-defaults/99-xinzhao-defaults"
wifi_defaults="$root/files/etc/uci-defaults/98-xinzhao-wifi-defaults"

[[ -f "$wifi_defaults" ]] || {
  echo 'FAIL: Wi-Fi defaults must run independently of the general first-boot marker.' >&2
  exit 1
}
grep -Fq "wifi_default_ssid='xinzhaowrt'" "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi defaults must define the authoritative SSID.' >&2
  exit 1
}
grep -Fq "wifi_default_password='12345678'" "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi migration defaults must define the locked password.' >&2
  exit 1
}
grep -Fq 'uci commit wireless' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi migration defaults must commit persistent UCI.' >&2
  exit 1
}
grep -Fq 'wifi reload' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi migration defaults must reload a running wireless service.' >&2
  exit 1
}
grep -Fq 'wifi config' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi defaults must generate radio config when first-boot UCI is absent.' >&2
  exit 1
}
grep -Fq 'wireless.$wifi_device.band' "$wifi_defaults" || {
  echo 'FAIL: Wi-Fi defaults must resolve band through each interface device.' >&2
  exit 1
}
grep -Fq 'wireless.$wifi_section.ssid=$wifi_default_ssid' "$wifi_defaults" || {
  echo 'FAIL: both radios must receive the authoritative SSID.' >&2
  exit 1
}
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)|12356789' "$wifi_defaults" || { echo 'FAIL: obsolete Wi-Fi defaults remain.' >&2; exit 1; }

grep -Fq "wifi_default_ssid='xinzhaowrt'" "$defaults" || {
  echo 'FAIL: first-boot defaults must define the authoritative Wi-Fi SSID.' >&2
  exit 1
}
grep -Fq "wifi_default_password='12345678'" "$defaults" || {
  echo 'FAIL: first-boot defaults must define the locked default Wi-Fi password.' >&2
  exit 1
}
grep -Fq 'wireless.$wifi_section.key=$wifi_default_password' "$defaults" || {
  echo 'FAIL: first-boot defaults must apply the password to each Wi-Fi interface.' >&2
  exit 1
}
grep -Fq 'wireless.$wifi_section.ssid=$wifi_default_ssid' "$defaults" || {
  echo 'FAIL: first-boot defaults must configure the unified SSID.' >&2
  exit 1
}
! grep -Eq 'XinZhaoWrt-(2\.4G|5G)|12356789' "$defaults" || { echo 'FAIL: obsolete Wi-Fi defaults remain.' >&2; exit 1; }
grep -Fq 'uci commit wireless' "$defaults" || {
  echo 'FAIL: Wi-Fi defaults must be committed to persistent UCI configuration.' >&2
  exit 1
}
grep -Fq 'wifi reload' "$defaults" || {
  echo 'FAIL: first-boot defaults must reload a running wireless service.' >&2
  exit 1
}

echo 'PASS: first-boot defaults configure the unified Wi-Fi identity.'
