#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/config/istore-quickstart.lock"
LINKER="$ROOT/scripts/add-custom-packages.sh"
CHECKER="$ROOT/scripts/check-package-sources.sh"
ROOTFS_VERIFY="$ROOT/scripts/verify-final-rootfs-identity.sh"
CONFIG="$ROOT/config/arthur.config"
REQUIRED="$ROOT/config/required-plugins.txt"
BOOT="$ROOT/files/etc/uci-defaults/zzzz-xinzhao-file-management"

fail() {
  echo "LINKEASE_SOURCE_BINDING: FAIL -- $*" >&2
  exit 1
}

grep -Fq 'ISTORE_QUICKSTART_LUCI_REF="8aa8467aabe86f1cf8d23fdb6b0cdd2ef14d2449"' "$LOCK" || fail 'nas-packages-luci ref drifted'
grep -Fq 'ISTORE_QUICKSTART_REF="0c789dc2b88f684476f6174201105da6ca6f5133"' "$LOCK" || fail 'nas-packages ref drifted'
grep -Fq 'ISTORE_LINKEASE_VERSION="1.7.5"' "$LOCK" || fail 'LinkEase version lock missing'
grep -Fq 'ISTORE_LINKEASE_RELEASE="8"' "$LOCK" || fail 'LinkEase package release lock missing'
grep -Fq 'ISTORE_LINKEASE_COMMON_BIN_VERSION="1.7.5"' "$LOCK" || fail 'LinkEase common binary version lock missing'
grep -Fq 'ISTORE_LINKEASE_COMMON_BIN_RELEASE="5"' "$LOCK" || fail 'LinkEase common package release lock missing'
grep -Fq 'ISTORE_LINKEASE_LUCI_VERSION="2.1.70"' "$LOCK" || fail 'LinkEase LuCI version lock missing'
grep -Fq 'ISTORE_LINKEASE_LUCI_RELEASE="3"' "$LOCK" || fail 'LinkEase LuCI release lock missing'
grep -Fq 'ISTORE_LINKEASE_AARCH64_BIN_SHA256="92d0c6f9d05a0ba283d03fef2b7f4675eee032c303e959b1e4198e12806510f9"' "$LOCK" || fail 'LinkEase AArch64 runtime hash lock missing'
grep -Fq 'ISTORE_LINKEASE_COMMON_AARCH64_BIN_SHA256="1646db48f5a512b96a34971e5af82eacd5a51f32abab2c5e84f277c408a72eb8"' "$LOCK" || fail 'LinkEase common AArch64 runtime hash lock missing'

grep -Fq 'link_pkg linkease-common-bin "$LINKEASE_COMMON_BIN_DIR"' "$LINKER" || fail 'common binary is not linked from the pinned official package source'
grep -Fq 'link_pkg linkease "$ISTOREOS_PACKAGES/network/services/linkease"' "$LINKER" || fail 'LinkEase daemon is not linked from the pinned official package source'
grep -Fq 'link_pkg luci-lib-linkeasefile "$ISTOREOS_LUCI/luci/luci-lib-linkeasefile"' "$LINKER" || fail 'file library is not linked from the pinned official LuCI source'
grep -Fq 'link_pkg luci-app-linkease "$ISTOREOS_LUCI/luci/luci-app-linkease"' "$LINKER" || fail 'LinkEase app is not linked from the pinned official LuCI source'
grep -Fq 'remove-linkease-wan-firewall-default.sh' "$LINKER" || fail 'the safe payload patch is not applied before package linking'
grep -Fq 'require_file "$ROOTFS_DIR/etc/uci-defaults/zzzz-xinzhao-file-management"' "$ROOTFS_VERIFY" || fail 'final rootfs gate does not verify first-boot persistence'
grep -Fq 'LinkEase WAN 8897 firewall UCI-default' "$ROOTFS_VERIFY" || fail 'final rootfs gate does not reject the LinkEase firewall default'

for pkg in linkease linkease-common-bin luci-lib-linkeasefile luci-app-linkease; do
  grep -Fxq "CONFIG_PACKAGE_${pkg}=y" "$CONFIG" || fail "$pkg is not selected in the firmware config"
  grep -Fq "assert_source $pkg " "$CHECKER" || fail "$pkg source provenance is not checked"
done

[[ "$(grep -Ec '^[^#[:space:]]' "$REQUIRED")" == 22 ]] || fail 'mandatory LuCI application baseline changed'
if grep -Eq '^[[:space:]]*luci-app-linkease([[:space:]]|$)' "$REQUIRED"; then
  fail 'LinkEase was added to the mandatory 22-app product baseline'
fi

[[ -x "$BOOT" ]] || fail 'first-boot file-management service script is missing or not executable'
grep -Fq '/etc/init.d/linkease enable' "$BOOT" || fail 'first-boot LinkEase persistence is missing'
grep -Fq '/etc/init.d/linkease start' "$BOOT" || fail 'first-boot LinkEase startup is missing'
grep -Fq '/etc/init.d/quickfile enable' "$BOOT" || fail 'first-boot QuickFile persistence is missing'
grep -Fq '/etc/init.d/quickfile start' "$BOOT" || fail 'first-boot QuickFile startup is missing'
if grep -Eiq 'firewall|nft|iptables|8897' "$BOOT"; then
  fail 'first-boot file-management script contains a firewall or WAN port change'
fi

VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
CONFIG_VERSION="$(sed -nE 's/^CONFIG_VERSION_NUMBER="([^"]+)"$/\1/p' "$CONFIG")"
[[ "$VERSION" == '0.1.6' && "$CONFIG_VERSION" == "$VERSION" ]] || fail 'v0.1.6 version identity is inconsistent'

echo 'LINKEASE_SOURCE_BINDING=PASS'
