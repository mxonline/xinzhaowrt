#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config/arthur.config"
packages="$root/scripts/add-custom-packages.sh"
build="$root/scripts/build.sh"
restore_adguard="$root/scripts/restore-pinned-adguard-manager.sh"
rootfs_verifier="$root/scripts/verify-final-rootfs-identity.sh"
manifest="$root/production/accepted-preview/arthur-adh-quickstart.json"
materializer="$root/scripts/materialize-accepted-overlay.py"
luci_converge="$root/files/usr/libexec/xinzhao/luci-upgrade-converge.sh"
luci_hotplug="$root/files/etc/hotplug.d/iface/95-xinzhao-luci-converge"

grep -Fxq 'CONFIG_PACKAGE_luci-theme-argon=y' "$config" || { echo 'FAIL: production config must embed Argon.' >&2; exit 1; }
grep -Fxq 'CONFIG_PACKAGE_luci-theme-kucat=y' "$config" || { echo 'FAIL: production config must embed KuCat.' >&2; exit 1; }
grep -Fq 'config/arthur-theme.lock' "$packages" || { echo 'FAIL: production package assembly must consume the frozen Arthur theme lock.' >&2; exit 1; }
grep -Fq 'jerrykuku/luci-theme-argon.git' "$packages" || { echo 'FAIL: production package assembly must use the frozen Argon source.' >&2; exit 1; }
grep -Fq 'sirpdboy/luci-theme-kucat.git' "$packages" || { echo 'FAIL: production package assembly must use the frozen KuCat source.' >&2; exit 1; }
grep -Fq 'link_pkg luci-theme-argon' "$packages" || { echo 'FAIL: Argon must enter the production xinzhao feed.' >&2; exit 1; }
grep -Fq 'link_pkg luci-theme-kucat' "$packages" || { echo 'FAIL: KuCat must enter the production xinzhao feed.' >&2; exit 1; }

[[ -s "$manifest" ]] || { echo 'FAIL: accepted arthur-adh-quickstart manifest is missing from the production source.' >&2; exit 1; }
[[ -x "$materializer" || -f "$materializer" ]] || { echo 'FAIL: accepted overlay materializer is missing.' >&2; exit 1; }
[[ -f "$luci_converge" ]] || { echo 'FAIL: production overlay must contain preserved-upgrade LuCI convergence.' >&2; exit 1; }
[[ -f "$luci_hotplug" ]] || { echo 'FAIL: production overlay must contain the LAN hotplug convergence trigger.' >&2; exit 1; }
grep -Fq 'materialize-accepted-overlay.py' "$build" || { echo 'FAIL: production build must materialize the frozen accepted overlay.' >&2; exit 1; }
grep -Fq 'ADGUARD_LEGACY_MANAGER_PURGE=PASS' "$restore_adguard" || { echo 'FAIL: production AdGuard normalization must purge legacy manager paths.' >&2; exit 1; }
grep -Fq 'mature AdGuard manager, zh_cn locale, themes, QuickStart, and preserved-upgrade LuCI convergence' "$rootfs_verifier" || { echo 'FAIL: final rootfs verifier is not bound to feature convergence.' >&2; exit 1; }
grep -Fq 'reject_exact_child_name' "$rootfs_verifier" || { echo 'FAIL: final rootfs verifier must reject case-distinct legacy AdGuard aliases without Windows CI false positives.' >&2; exit 1; }
python3 "$materializer" --root "$root" --manifest "production/accepted-preview/arthur-adh-quickstart.json" --check
bash "$root/tests/test-adguard-overlay-precedence.sh"
bash "$root/tests/test-preserved-upgrade-luci-convergence.sh"
bash "$root/tests/test-final-rootfs-identity.sh"

echo 'SELF_CONTAINED_PRODUCTION_CANDIDATE=PASS'
