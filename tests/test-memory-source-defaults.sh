#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="$root/files/etc/uci-defaults/96-xinzhao-adguardhome-defaults"
adguard_config="$root/files/etc/config/adguardhome"
required="$root/config/required-plugins.txt"
arthur_config="$root/config/arthur.config"

fail() { echo "MEMORY_SOURCE_DEFAULTS_GATE: FAIL -- $*" >&2; exit 1; }

[[ -s "$defaults" ]] || fail 'AdGuardHome default reconciler is missing'
[[ -s "$adguard_config" ]] || fail 'official lowercase AdGuardHome config is missing'
grep -Eq "^[[:space:]]*option enabled '0'[[:space:]]*$" "$adguard_config" || fail 'AdGuardHome is not default-off'
for service in adguardhome AdGuardHome quickfile; do
  grep -Fq "disable_service $service" "$defaults" || fail "default reconciler does not disable $service"
done
! grep -Fq '/etc/init.d/quickstart disable' "$defaults" || fail 'QuickStart must remain enabled'
! grep -Fq 'killall' "$defaults" || fail 'source fix must not use killall'
grep -Fq 'luci-app-quickfile' "$required" || fail 'QuickFile package contract missing'
grep -Fq 'luci-app-quickstart' "$required" || fail 'QuickStart package contract missing'
for package in $(grep -Ev '^[[:space:]]*(#|$)' "$required"); do
  grep -qxF "CONFIG_PACKAGE_${package}=y" "$arthur_config" || fail "required plugin is not enabled: $package"
done
for patch in "$root"/patches/openclash/*.patch; do [[ -s "$patch" ]] || fail "missing OpenClash patch: $patch"; done
echo 'MEMORY_SOURCE_DEFAULTS_GATE=PASS'
