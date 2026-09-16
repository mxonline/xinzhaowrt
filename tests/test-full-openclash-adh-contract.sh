#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/arthur.config"
BUILD="$ROOT/scripts/build.sh"
TARGETS="$ROOT/production/ARTHUR_PRODUCT_TARGETS.md"
CORE_LOCK="$ROOT/config/openclash-core.lock"
CORE_STAGE="$ROOT/scripts/stage-openclash-core.sh"
CORE_LIFECYCLE="$ROOT/tests/test-openclash-core-lifecycle.py"
ROOTFS_VERIFY="$ROOT/scripts/verify-firmware-openclash-adh.sh"
PREFLIGHT="$ROOT/.github/workflows/arthur-fast-preflight.yml"
BUILD_WORKFLOW="$ROOT/.github/workflows/build.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# AdGuardHome must be a complete offline-capable product, not a LuCI shell that
# downloads its daemon on first use.
grep -Fxq 'CONFIG_PACKAGE_luci-app-adguardhome=y' "$CONFIG" || fail 'AdGuardHome LuCI manager must remain selected'
grep -Fxq 'CONFIG_PACKAGE_luci-app-adguardhome_INCLUDE_binary=y' "$CONFIG" || fail 'AdGuardHome binary must be bundled with the mature LuCI manager'

# OpenClash must ship a pinned Meta/Mihomo core for Arthur arm64 so first start
# cannot depend on a live GitHub/core download.
[[ -f "$CORE_LOCK" ]] || fail 'OpenClash core lock is missing'
# shellcheck disable=SC1090
source "$CORE_LOCK"
[[ "${OPENCLASH_CORE_REPO:-}" == 'https://github.com/vernesong/OpenClash.git' ]] || fail 'OpenClash core must come from the official OpenClash repository'
[[ "${OPENCLASH_CORE_REF:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'OpenClash core ref must be an immutable commit SHA'
[[ "${OPENCLASH_CORE_BRANCH:-}" == 'master' ]] || fail 'OpenClash core must use the stable master branch assets'
[[ "${OPENCLASH_CORE_FLAVOR:-}" == 'meta' ]] || fail 'Arthur must bundle the Meta/Mihomo core'
[[ "${OPENCLASH_CORE_ARCH:-}" == 'linux-arm64' ]] || fail 'Arthur OpenClash core architecture must be linux-arm64'
[[ "${OPENCLASH_CORE_GIT_BLOB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'OpenClash core blob identity must be pinned'
[[ "${OPENCLASH_CORE_INSTALL_PATH:-}" == '/etc/openclash/core/clash_meta' ]] || fail 'OpenClash core install path must match the official OpenClash runtime path'

[[ -f "$CORE_STAGE" ]] || fail 'OpenClash core staging helper is missing'
[[ -f "$CORE_LIFECYCLE" ]] || fail 'OpenClash core lifecycle contract is missing'
[[ -f "$ROOTFS_VERIFY" ]] || fail 'final firmware OpenClash/AdGuardHome rootfs verifier is missing'
[[ -f "$BUILD_WORKFLOW" ]] || fail 'FULL_BUILD workflow is missing'
grep -Fq 'run: bash ./scripts/codex-setup.sh' "$BUILD_WORKFLOW" || fail 'FULL_BUILD workflow must invoke dependency setup through bash'
grep -Fq 'stage-openclash-core.sh' "$BUILD" || fail 'build must stage the pinned OpenClash core before firmware compilation'
grep -Fq 'verify-firmware-openclash-adh.sh' "$BUILD" || fail 'build must verify complete OpenClash and AdGuardHome in the final firmware rootfs'
CORE_PYTHON="${PYTHON_BIN:-$(command -v python3 || command -v python || true)}"
[[ -n "$CORE_PYTHON" ]] || fail 'OpenClash core lifecycle contract requires Python'
"$CORE_PYTHON" "$CORE_LIFECYCLE" || fail 'OpenClash core lifecycle contract failed'

# The final-rootfs verifier runs as an unprivileged GitHub Actions user. It must
# never unpack the whole SquashFS tree because /dev/console and other device
# nodes require root privileges. Inspect only the required regular files and
# their metadata with unsquashfs -cat/-ll.
if grep -Eq '"?\$UNSQUASHFS"?[[:space:]]+-d[[:space:]]' "$ROOTFS_VERIFY"; then
  fail 'final rootfs verifier must not fully extract SquashFS as an unprivileged runner'
fi
grep -Fq '"$UNSQUASHFS" -cat "$tmp/root.squashfs"' "$ROOTFS_VERIFY" || fail 'rootfs verifier must inspect required files with unsquashfs -cat'
grep -Fq '"$UNSQUASHFS" -ll "$tmp/root.squashfs"' "$ROOTFS_VERIFY" || fail 'rootfs verifier must inspect executable metadata with unsquashfs -ll'

# A repair that changes firmware composition is classified FULL_BUILD. Its PR
# must execute the exact source/feed/package/defconfig closure automatically;
# static tests alone are not sufficient evidence for a firmware repair.
grep -Fq 'outputs:' "$PREFLIGHT" || fail 'preflight job must publish its resolved build scope'
grep -Fq 'scope: ${{ steps.changes.outputs.scope }}' "$PREFLIGHT" || fail 'preflight job must expose the resolved build scope to build-closure'
grep -Fq "needs.preflight.outputs.scope == 'FULL_BUILD'" "$PREFLIGHT" || fail 'FULL_BUILD pull requests must automatically run build closure'
grep -Fq "needs.preflight.outputs.scope == 'SDK_BUILD'" "$PREFLIGHT" || fail 'SDK_BUILD pull requests must automatically run build closure'
grep -Fq "CLOSURE_MODE=\"rebuild_known_good\"" "$PREFLIGHT" || fail 'PR build closure must use a deterministic rebuild_known_good lock mode'

grep -Fq 'OPENCLASH_FULLY_USABLE=PASS' "$TARGETS" || fail 'product target must define complete OpenClash usability as the acceptance endpoint'
grep -Fq 'ADGUARDHOME_FULLY_USABLE=PASS' "$TARGETS" || fail 'product target must define complete AdGuardHome usability as the acceptance endpoint'
grep -Fq 'OPENCLASH_ADH_COEXISTENCE=PASS' "$TARGETS" || fail 'product target must require OpenClash + AdGuardHome coexistence after release'

echo 'FULL_OPENCLASH_ADH_CONTRACT=PASS'
