#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"
FILE="$PROJECT_ROOT/files/etc/uci-defaults/99-xinzhao-defaults"

[[ "$DEFAULT_ROOT_USER" == "root" ]] || { echo "ERROR: OpenWrt admin user must remain root for this project."; exit 1; }

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required to verify default root credential semantics"; exit 1; }
password_hash_algo="$(printf '%s' "$DEFAULT_ROOT_PASSWORD_HASH" | cut -d 'grep -qF "network.lan.ipaddr='$DEFAULT_LAN_IP/24'" "$FILE" || { echo "ERROR: LAN IPv4/CIDR mismatch"; exit 1; }
grep -qF "password_hash='$DEFAULT_ROOT_PASSWORD_HASH'" "$FILE" || { echo "ERROR: root password hash mismatch"; exit 1; }
grep -qF "xinzhaowrt.system.initialized='1'" "$FILE" || { echo "ERROR: persistent initialization marker missing"; exit 1; }

echo "PASS: first-boot defaults match build.env ($DEFAULT_LAN_IP / $DEFAULT_ROOT_USER) and are upgrade-safe."
 -f2)"
password_hash_salt="$(printf '%s' "$DEFAULT_ROOT_PASSWORD_HASH" | cut -d 'grep -qF "network.lan.ipaddr='$DEFAULT_LAN_IP/24'" "$FILE" || { echo "ERROR: LAN IPv4/CIDR mismatch"; exit 1; }
grep -qF "password_hash='$DEFAULT_ROOT_PASSWORD_HASH'" "$FILE" || { echo "ERROR: root password hash mismatch"; exit 1; }
grep -qF "xinzhaowrt.system.initialized='1'" "$FILE" || { echo "ERROR: persistent initialization marker missing"; exit 1; }

echo "PASS: first-boot defaults match build.env ($DEFAULT_LAN_IP / $DEFAULT_ROOT_USER) and are upgrade-safe."
 -f3)"
[[ "$password_hash_algo" == "6" && -n "$password_hash_salt" ]] || { echo "ERROR: DEFAULT_ROOT_PASSWORD_HASH must be SHA-512 crypt"; exit 1; }
derived_root_password_hash="$(printf '%s' "$DEFAULT_ROOT_PASSWORD" | openssl passwd -6 -salt "$password_hash_salt" -stdin)"
[[ "$derived_root_password_hash" == "$DEFAULT_ROOT_PASSWORD_HASH" ]] || { echo "ERROR: DEFAULT_ROOT_PASSWORD does not cryptographically match DEFAULT_ROOT_PASSWORD_HASH"; exit 1; }
grep -qF "network.lan.ipaddr='$DEFAULT_LAN_IP/24'" "$FILE" || { echo "ERROR: LAN IPv4/CIDR mismatch"; exit 1; }
grep -qF "password_hash='$DEFAULT_ROOT_PASSWORD_HASH'" "$FILE" || { echo "ERROR: root password hash mismatch"; exit 1; }
grep -qF "xinzhaowrt.system.initialized='1'" "$FILE" || { echo "ERROR: persistent initialization marker missing"; exit 1; }

echo "PASS: first-boot defaults match build.env ($DEFAULT_LAN_IP / $DEFAULT_ROOT_USER) and are upgrade-safe."
