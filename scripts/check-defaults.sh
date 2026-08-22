#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"
FILE="$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults"

[[ "$DEFAULT_ROOT_USER" == "root" ]] || { echo "ERROR: OpenWrt admin user must remain root for this project."; exit 1; }
grep -qF "network.lan.ipaddr='$DEFAULT_LAN_IP'" "$FILE" || { echo "ERROR: LAN IP mismatch"; exit 1; }
grep -qF "password_hash='$DEFAULT_ROOT_PASSWORD_HASH'" "$FILE" || { echo "ERROR: root password hash mismatch"; exit 1; }
grep -qF "xinzhaowrt.system.initialized='1'" "$FILE" || { echo "ERROR: persistent initialization marker missing"; exit 1; }

echo "PASS: first-boot defaults match build.env ($DEFAULT_LAN_IP / $DEFAULT_ROOT_USER) and are upgrade-safe."
