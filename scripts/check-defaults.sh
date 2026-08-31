#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# v4.3 production hard gate. Development/preflight workflows are explicitly
# skipped by production-build-entry-gate.sh, while candidate workflows are
# denied until the complete batched changeset is marked PASS and frozen.
bash "$PROJECT_ROOT/scripts/production-build-entry-gate.sh"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"
FILE="$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults"

[[ -x "$FILE" ]] || { echo "ERROR: first-boot defaults script must be executable in the rootfs overlay"; exit 1; }

[[ "$DEFAULT_ROOT_USER" == "root" ]] || { echo "ERROR: OpenWrt admin user must remain root for this project."; exit 1; }
grep -qF "network.lan.ipaddr='${DEFAULT_LAN_IP}/24'" "$FILE" || { echo "ERROR: LAN IP mismatch"; exit 1; }
grep -qF "'192.168.1.1/24'" "$FILE" || { echo "ERROR: CIDR-form upstream LAN default is not handled"; exit 1; }
grep -qF "password_hash='$DEFAULT_ROOT_PASSWORD_HASH'" "$FILE" || { echo "ERROR: root password hash mismatch"; exit 1; }
grep -qF "xinzhaowrt.system.initialized='1'" "$FILE" || { echo "ERROR: persistent initialization marker missing"; exit 1; }
grep -qF 'marker_file="$config_dir/xinzhaowrt"' "$FILE" || { echo "ERROR: marker package path is not explicit"; exit 1; }
grep -qF 'mv -f "$marker_tmp" "$marker_file" || fail marker_package_create' "$FILE" || { echo "ERROR: marker package is not atomically created"; exit 1; }
grep -qF 'uci commit xinzhaowrt || fail marker_commit' "$FILE" || { echo "ERROR: initialization marker commit is not fail-closed"; exit 1; }
grep -qF "log 'FIRSTBOOT_COMPLETE'" "$FILE" || { echo "ERROR: completion evidence missing"; exit 1; }

echo "FIRST_BOOT_STATIC_CHECK: PASS ($DEFAULT_LAN_IP / $DEFAULT_ROOT_USER)"
