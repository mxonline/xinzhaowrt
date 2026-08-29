#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/arthur-theme-candidate.yml"
lock="$root/config/arthur-theme.lock"

fail() { echo "ARTHUR_THEME_GATE: FAIL -- $*" >&2; exit 1; }

[[ -f "$workflow" ]] || fail 'theme candidate workflow is missing'
[[ -f "$lock" ]] || fail 'theme provenance lock is missing'
grep -Fxq 'ARGON_REF="136eb5d42f30554e89cc737fd90f503909810660"' "$lock" || fail 'Argon ref is not frozen'
grep -Fxq 'KUCAT_REF="82ddd7e4196887089c43af19d4552cd54fa414d2"' "$lock" || fail 'Kucat ref is not frozen'
grep -Fq 'luci-theme-argon' "$workflow" || fail 'Argon package is absent'
grep -Fq 'luci-theme-kucat' "$workflow" || fail 'Kucat package is absent'
grep -Fq './tests/test-argon-default-theme.sh' "$workflow" || fail 'Argon factory-default regression test is not run by the workflow'
grep -Fq 'cd "$SDK_DIR" && ./scripts/feeds update luci' "$workflow" || fail 'SDK LuCI feed update does not run from the SDK root'
grep -Fq 'SDK_LUCI_FEED_MISSING' "$workflow" || fail 'SDK LuCI feed missing gate is absent'
grep -Fq 'feeds/luci/luci.mk' "$workflow" || fail 'SDK luci.mk gate is absent'
grep -Fq 'LUCI_FEED_COMMIT' "$workflow" || fail 'LuCI feed provenance is absent'
grep -Fq 'mkdir -p repository-staging' "$workflow" || fail 'ImageBuilder package staging directory is not prepared'
! grep -Fq 'mkdir -p "$IB_DIR/repositories"' "$workflow" || fail 'ImageBuilder repository configuration path is used as a staging directory'
grep -Fq 'IMAGEBUILDER_PACKAGE_MISSING' "$workflow" || fail 'ImageBuilder required-package gate is absent'
grep -Fq 'required_ib_packages=(argon luci-theme-kucat luci-i18n-base-zh-cn wget)' "$workflow" || fail 'ImageBuilder does not use the frozen Argon package name'
grep -Fq 'CONFIG_LUCI_LANG_zh_Hans=y' "$workflow" || fail 'locked Chinese LuCI translation is not enabled as a boolean SDK symbol'
grep -Fq 'scripts/feeds install luci-base' "$workflow" || fail 'locked LuCI base package is not installed through the SDK feed mechanism'
grep -Fq 'SDK_LUCI_BASE_FEED_PACKAGE_MISSING' "$workflow" || fail 'SDK LuCI base package presence gate is absent'
grep -Fq 'scripts/feeds update base' "$workflow" || fail 'locked ImmortalWrt base feed is not prepared for ucode headers'
grep -Fq 'scripts/feeds install -p base ucode' "$workflow" || fail 'SDK ucode package is not installed from the locked base feed'
grep -Fq 'SDK_UCODE_FEED_PACKAGE_MISSING' "$workflow" || fail 'SDK ucode feed package presence gate is absent'
grep -Fq 'package/feeds/base/ucode/compile' "$workflow" || fail 'SDK ucode package is not compiled before LuCI'
grep -Fq 'UCODE_HEADER=PASS' "$workflow" || fail 'ucode header staging gate is absent'
grep -Fq 'UCODE_STAGING=PASS' "$workflow" || fail 'ucode library staging gate is absent'
grep -Fq 'UCODE_COMMIT' "$workflow" || fail 'ucode provenance is absent'
grep -Fq 'package/feeds/luci/lucihttp/compile' "$workflow" || fail 'liblucihttp-ucode preflight compile is absent'
grep -Fq 'SDK_DEPENDENCY_CLOSURE=PASS' "$workflow" || fail 'SDK dependency closure gate is absent'
defconfig_line="$(grep -nF 'make -C "$SDK_DIR" defconfig' "$workflow" | cut -d: -f1 | head -n1)"
ucode_compile_line="$(grep -nF 'package/feeds/base/ucode/compile' "$workflow" | cut -d: -f1 | head -n1)"
lucihttp_compile_line="$(grep -nF 'package/feeds/luci/lucihttp/compile' "$workflow" | cut -d: -f1 | head -n1)"
test -n "$defconfig_line" && test -n "$ucode_compile_line" && test "$defconfig_line" -lt "$ucode_compile_line" || fail 'ucode compile runs before SDK defconfig'
test "$defconfig_line" -lt "$lucihttp_compile_line" || fail 'lucihttp preflight runs before SDK defconfig'
grep -Fq 'immortalwrt.git\$#' "$workflow" || fail 'base feed sed anchor does not escape the shell $# expansion'
! grep -Fq 'immortalwrt.git$#' "$workflow" || fail 'base feed sed anchor still expands the shell $# token'
grep -Fq 'CONFIG_PACKAGE_liblucihttp-lua=n' "$workflow" || fail 'SDK translation lane still enables the unnecessary Lua lucihttp variant'
grep -Fq 'package/feeds/luci/luci-base/compile' "$workflow" || fail 'locked LuCI base translation package is not compiled by the SDK'
grep -Fq -- "-name 'luci-i18n-base-zh-cn-*.apk'" "$workflow" || fail 'Chinese LuCI package is not staged for ImageBuilder'
! grep -Eq 'mediaurlbase=.*(argon|kucat)' "$workflow" || fail 'workflow forces a theme default'
! grep -Eq 'curl[[:space:]]+-k|--insecure|Client-ID' "$workflow" || fail 'workflow contains insecure online-theme logic'
! grep -Eq 'make world|FULL_BUILD' "$workflow" || fail 'workflow contains prohibited full build'
echo 'ARTHUR_THEME_GATE: PASS'
