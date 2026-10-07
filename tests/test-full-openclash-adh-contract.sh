#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/arthur.config"
BUILD="$ROOT/scripts/build.sh"
TARGETS="$ROOT/production/ARTHUR_PRODUCT_TARGETS.md"
META_LOCK="$ROOT/config/openclash-core.lock.json"
SMART_LOCK="$ROOT/config/openclash-smart-core.lock.json"
CORE_BUNDLE_TEST="$ROOT/tests/test-openclash-core-bundle.py"
ROOTFS_VERIFY_CORE="$ROOT/scripts/verify-final-rootfs-openclash-core.py"
ROOTFS_VERIFY_ADH="$ROOT/scripts/verify-final-rootfs-adh-manager.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Retain Stable's shipped AdGuard manager and its firmware-owned OpenClash Core.
for package in luci-app-adguardhome luci-app-adguardhome-manager openclash-core; do
  grep -Fxq "CONFIG_PACKAGE_${package}=y" "$CONFIG" || fail "$package must remain enabled in the Stable Arthur configuration"
done

# The exact Stable core implementation is pinned in two official AArch64 locks.
[[ -f "$META_LOCK" && -f "$SMART_LOCK" ]] || fail 'Stable OpenClash Meta/Smart Core locks are missing'
"$PYTHON_BIN" - "$META_LOCK" "$SMART_LOCK" <<'PY'
import json
import re
import sys

meta, smart = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
for kind, lock in (("Meta", meta), ("Smart", smart)):
    if lock.get("source_repository") != "vernesong/OpenClash":
        raise SystemExit(f"FAIL: {kind} core must use the official OpenClash source")
    if not re.fullmatch(r"[0-9a-f]{40}", str(lock.get("source_ref", ""))):
        raise SystemExit(f"FAIL: {kind} core source ref must be immutable")
    if lock.get("core_type") != kind or lock.get("asset_path") != f"master/{kind.lower()}/clash-linux-arm64.tar.gz":
        raise SystemExit(f"FAIL: {kind} core lock does not select its official AArch64 asset")
    if lock.get("install_path") != f"/etc/openclash/core/clash_{kind.lower()}":
        raise SystemExit(f"FAIL: {kind} core install path changed")
    if lock.get("elf_class") != 64 or lock.get("elf_machine") != 183:
        raise SystemExit(f"FAIL: {kind} core lock is not AArch64")
if meta.get("source_ref") != smart.get("source_ref"):
    raise SystemExit("FAIL: Meta and Smart cores must use one locked OpenClash commit")
PY

[[ -f "$CORE_BUNDLE_TEST" ]] || fail 'Stable OpenClash Core bundle regression test is missing'
"$PYTHON_BIN" "$CORE_BUNDLE_TEST" || fail 'Stable OpenClash Core bundle regression test failed'
[[ -f "$ROOTFS_VERIFY_CORE" && -f "$ROOTFS_VERIFY_ADH" ]] || fail 'final firmware OpenClash/AdGuardHome rootfs verifiers are missing'
grep -Fq 'fetch-openclash-core.sh' "$BUILD" || fail 'build must stage Stable locked OpenClash Cores before firmware compilation'
grep -Fq 'verify-final-rootfs-openclash-core.py' "$BUILD" || fail 'build must verify OpenClash cores in the final firmware rootfs'
grep -Fq 'verify-final-rootfs-adh-manager.py' "$BUILD" || fail 'build must verify the AdGuardHome manager in the final firmware rootfs'

grep -Fq 'OPENCLASH_FULLY_USABLE=PASS' "$TARGETS" || fail 'product target must define complete OpenClash usability'
grep -Fq 'ADGUARDHOME_FULLY_USABLE=PASS' "$TARGETS" || fail 'product target must define complete AdGuardHome usability'
grep -Fq 'OPENCLASH_ADH_COEXISTENCE=PASS' "$TARGETS" || fail 'product target must require OpenClash + AdGuardHome coexistence'

# These current-main helpers were not part of the real-device-confirmed Stable
# product source and are not called by the Stable build. Keep them out of v0.1.6.
for unproven in \
  scripts/patch-adguardhome-coexistence.py \
  scripts/patch-openclash-core-lifecycle.py \
  scripts/stage-openclash-core.sh; do
  [[ ! -e "$ROOT/$unproven" ]] || fail "unproven current-main product helper remains: $unproven"
done

echo 'FULL_OPENCLASH_ADH_CONTRACT=PASS'
