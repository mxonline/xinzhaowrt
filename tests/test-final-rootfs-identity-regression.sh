#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

version="$(tr -d '\r\n' < "$project_root/VERSION")"
old_version='0.1.3'
if [[ "$version" == "$old_version" ]]; then
  old_version='0.1.2'
fi
commit='27e26e324bee0b0c2a4eb58e2e9121fea5d43194'
build_id='replacement-test-id'
config="$fixture/full.config"
rootfs="$fixture/rootfs"
mkdir -p "$rootfs/etc/uci-defaults" "$rootfs/www/luci-static/xinzhao"
cat > "$config" <<CONFIG
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="XinZhaoWrt"
CONFIG_VERSION_NUMBER="$version"
CONFIG_VERSION_MANUFACTURER="XinZhao Network"
CONFIG_VERSION_PRODUCT="JDCloud Arthur RE-SS-01"
CONFIG
cat > "$rootfs/etc/openwrt_release" <<RELEASE
DISTRIB_ID='XinZhaoWrt'
DISTRIB_RELEASE='$version'
DISTRIB_REVISION='r0+1-${commit:0:9}'
DISTRIB_TARGET='qualcommax/ipq60xx'
DISTRIB_ARCH='aarch64_cortex-a53'
RELEASE
cat > "$rootfs/etc/os-release" <<RELEASE
NAME='XinZhaoWrt'
VERSION='$version'
VERSION_ID='$version'
BUILD_ID='$build_id'
RELEASE
cat > "$rootfs/etc/xinzhao-build-info" <<INFO
Firmware: XinZhaoWrt
Version: $version
Git Commit: ${commit:0:9}
Build ID: $build_id
Target: qualcommax/ipq60xx
Profile: jdcloud_re-ss-01
INFO
cat > "$rootfs/www/luci-static/xinzhao/build-info.json" <<INFO
{"Firmware":"XinZhaoWrt","Version":"$version","Git Commit":"${commit:0:9}","Build ID":"$build_id","Target":"qualcommax/ipq60xx","Profile":"jdcloud_re-ss-01"}
INFO
cp "$project_root/files/etc/uci-defaults/99-xinzhao-defaults" "$rootfs/etc/uci-defaults/99-xinzhao-defaults"

if ! bash "$project_root/scripts/verify-final-rootfs-identity.sh" "$config" "$rootfs" "$commit" "$build_id"; then
  echo 'FAIL: verifier rejected a synchronized identity fixture' >&2
  exit 1
fi

sed -i "s/Version: $version/Version: $old_version/" "$rootfs/etc/xinzhao-build-info"
if bash "$project_root/scripts/verify-final-rootfs-identity.sh" "$config" "$rootfs" "$commit" "$build_id"; then
  echo 'FAIL: verifier accepted stale /etc/xinzhao-build-info' >&2
  exit 1
fi

sed -i "s/Version: $old_version/Version: @VERSION@/" "$rootfs/etc/xinzhao-build-info"
if bash "$project_root/scripts/verify-final-rootfs-identity.sh" "$config" "$rootfs" "$commit" "$build_id"; then
  echo 'FAIL: verifier accepted a build-info placeholder' >&2
  exit 1
fi

echo 'FINAL_ROOTFS_IDENTITY_STALE_VERSION=PASS'
echo 'FINAL_ROOTFS_IDENTITY_PLACEHOLDER=PASS'
