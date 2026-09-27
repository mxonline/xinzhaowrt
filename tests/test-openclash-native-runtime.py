#!/usr/bin/env python3
"""Regression contract for the proven native OpenClash runtime path."""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/add-custom-packages.sh"
DEFAULTS = ROOT / "files/etc/uci-defaults/95-xinzhao-openclash-defaults"
LEGACY_SELECTOR = ROOT / "files/usr/libexec/xinzhao-openclash-core-select"
CORE_VM_PATCH = ROOT / "patches/openclash/0015-smart-core-luci-vm-limit.patch"


def main() -> int:
    hook = HOOK.read_text(encoding="utf-8")
    if "0015-smart-core-luci-vm-limit.patch" not in hook:
        raise AssertionError("LuCI Smart Core VMA-limit patch is not wired into the build")
    if 'git -C "$SOURCES/OpenClash" apply "$CORE_VM_PATCH"' not in hook:
        raise AssertionError("LuCI Smart Core VMA-limit patch is not applied to OpenClash")
    if "0015-smart-auto-select-policy.patch" in hook or "SMART_POLICY_PATCH" in hook:
        raise AssertionError("obsolete one-group Smart YAML patch remains wired into the build")
    if "0014-smart-core-bundle-and-runtime-selection.patch" in hook:
        raise AssertionError("legacy Smart Core init patch is still wired into the build")
    if "xinzhao-openclash-core-select" in hook:
        raise AssertionError("legacy selector is still wired into the OpenClash build")

    defaults = DEFAULTS.read_text(encoding="utf-8")
    required = (
        "uci -q set openclash.config.smart_enable='1'",
        "uci -q set openclash.config.core_type='Smart'",
        "uci -q set openclash.config.auto_smart_switch='1'",
        "clash-verge/v2.4.5",
    )
    for marker in required:
        if marker not in defaults:
            raise AssertionError(f"native OpenClash default is missing: {marker}")
    if LEGACY_SELECTOR.exists():
        raise AssertionError("legacy OpenClash selector must not be shipped")
    vm_patch = CORE_VM_PATCH.read_text(encoding="utf-8")
    if "luasrc/controller/openclash.lua" not in vm_patch or "ulimit -v unlimited" not in vm_patch:
        raise AssertionError("the LuCI Smart Core VMA-limit patch is missing its controller guard")

    print("OPENCLASH_NATIVE_RUNTIME_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
