#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="$root/files/etc/uci-defaults/96-xinzhao-adguardhome-defaults"
adguard_config="$root/files/etc/config/adguardhome"
required="$root/config/required-plugins.txt"
arthur_config="$root/config/arthur.config"

fail() {
  echo "MEMORY_SOURCE_DEFAULTS_GATE: FAIL -- $*" >&2
  exit 1
}

pass() {
  echo "$1=PASS"
}

[[ -s "$defaults" ]] || fail 'AdGuardHome default reconciler is missing'
[[ -s "$adguard_config" ]] || fail 'official lowercase AdGuardHome config is missing'
grep -Eq "^[[:space:]]*option enabled '0'[[:space:]]*$" "$adguard_config" || {
  fail 'AdGuardHome package config is not default-off'
}

for service in adguardhome AdGuardHome quickfile; do
  grep -Fq "disable_service $service" "$defaults" || {
    fail "default reconciler does not disable $service"
  }
done
! grep -Fq '/etc/init.d/quickstart disable' "$defaults" || {
  fail 'default reconciler must preserve QuickStart autostart'
}
! grep -Fq 'killall' "$defaults" || {
  fail 'default reconciler must not use killall as a source fix'
}

grep -Fq 'luci-app-quickfile' "$required" || fail 'QuickFile required package contract is missing'
grep -Fq 'luci-app-quickstart' "$required" || fail 'QuickStart required package contract is missing'
grep -Fq 'luci-app-quickfile' "$arthur_config" || fail 'QuickFile is not enabled in Arthur config'
grep -Fq 'luci-app-quickstart' "$arthur_config" || fail 'QuickStart is not enabled in Arthur config'
grep -Fq 'nas-packages-luci.git' "$root/scripts/add-custom-packages.sh" || fail 'official QuickStart UI source is missing'
grep -Fq 'nas-packages.git' "$root/scripts/add-custom-packages.sh" || fail 'official QuickStart service source is missing'

for patch in \
  "$root/patches/openclash/0001-core-updater-single-flight-and-private-tmp.patch" \
  "$root/patches/openclash/0002-config-rewrite-no-shell-fork.patch" \
  "$root/patches/openclash/0003-yaml-age-lookup-no-shell-fork.patch"; do
  [[ -s "$patch" ]] || fail "OpenClash patch is missing: $(basename "$patch")"
done

plugin_count="$(grep -Ev '^[[:space:]]*(#|$)' "$required" | wc -l | tr -d ' ')"
[[ "$plugin_count" == 22 ]] || fail "expected 22 required plugins, found $plugin_count"
while IFS= read -r package; do
  package="${package%$'\r'}"
  [[ -z "$package" || "$package" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${package}=y" "$arthur_config" || {
    fail "required plugin is not enabled: $package"
  }
done < "$required"

pass ADGUARD_INSTALLED
pass ADGUARD_MANAGER
pass ADGUARD_DEFAULT_OFF
pass ADGUARD_NO_DEFAULT_PROCESS
pass QUICKFILE_INSTALLED
pass QUICKFILE_DEFAULT_DAEMON_OFF
pass QUICKSTART_INSTALLED
pass QUICKSTART_UI_CONTRACT
pass OPENCLASH_PATCH_0001
pass OPENCLASH_PATCH_0002
pass OPENCLASH_PATCH_0003
pass REQUIRED_PLUGINS_22
pass MEMORY_SOURCE_DEFAULTS_GATE
