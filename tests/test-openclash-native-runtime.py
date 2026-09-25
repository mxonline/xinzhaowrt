#!/usr/bin/env python3
"""Regression contract for the proven native OpenClash runtime path."""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/add-custom-packages.sh"
DEFAULTS = ROOT / "files/etc/uci-defaults/95-xinzhao-openclash-defaults"
LEGACY_SELECTOR = ROOT / "files/usr/libexec/xinzhao-openclash-core-select"


def main() -> int:
    hook = HOOK.read_text(encoding="utf-8")
    if 'git -C "$SOURCES/OpenClash" apply' in hook:
        raise AssertionError("OpenClash build path still applies a project runtime patch")
    if "0014-smart-core-bundle-and-runtime-selection.patch" in hook:
        raise AssertionError("legacy Smart Core init patch is still wired into the build")
    if "xinzhao-openclash-core-select" in hook:
        raise AssertionError("legacy selector is still wired into the OpenClash build")

    defaults = DEFAULTS.read_text(encoding="utf-8")
    required = (
        "uci -q set openclash.config.smart_enable='1'",
        "uci -q set openclash.config.core_type='Smart'",
        "clash-verge/v2.4.5",
    )
    for marker in required:
        if marker not in defaults:
            raise AssertionError(f"native OpenClash default is missing: {marker}")
    if LEGACY_SELECTOR.exists():
        raise AssertionError("legacy OpenClash selector must not be shipped")

    print("OPENCLASH_NATIVE_RUNTIME_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
