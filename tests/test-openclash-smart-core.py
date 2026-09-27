#!/usr/bin/env python3
"""Static regression checks for OpenClash's native Smart Core path."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/add-custom-packages.sh"
DEFAULTS = ROOT / "files/etc/uci-defaults/95-xinzhao-openclash-defaults"
CORE_VM_PATCH = ROOT / "patches/openclash/0015-smart-core-luci-vm-limit.patch"


def check_prepared_source() -> None:
    source_text = os.environ.get("OPENCLASH_NATIVE_SOURCE_ROOT")
    if not source_text:
        return
    source_root = Path(source_text)
    init = source_root / "luci-app-openclash/root/etc/init.d/openclash"
    updater = source_root / "luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
    rules = source_root / "luci-app-openclash/root/usr/share/openclash/yml_rules_change.sh"
    controller = source_root / "luci-app-openclash/luasrc/controller/openclash.lua"
    if not init.is_file() or not updater.is_file() or not rules.is_file() or not controller.is_file():
        raise AssertionError("prepared official OpenClash source is incomplete")
    init_text = init.read_text(encoding="utf-8")
    updater_text = updater.read_text(encoding="utf-8")
    rules_text = rules.read_text(encoding="utf-8")
    controller_text = controller.read_text(encoding="utf-8")
    required_init = (
        'meta_core_path="/etc/openclash/core/clash_meta"',
        'ln -s "$meta_core_path" /etc/openclash/clash',
        'change_dnsmasq "$enable_redirect_dns"',
        "set_firewall",
        'openclash_core.sh "$core_type"',
        'auto_smart_switch=$(uci_get_config "auto_smart_switch" || echo 0)',
        '"$auto_smart_switch" "$smart_collect"',
    )
    for marker in required_init:
        if marker not in init_text:
            raise AssertionError(f"official OpenClash init contract is missing: {marker}")
    if "/usr/libexec/xinzhao-openclash-core-select" in init_text:
        raise AssertionError("legacy selector remains in prepared OpenClash init")
    if "Pinned firmware Smart Core is immutable" in updater_text:
        raise AssertionError("legacy updater override remains in prepared OpenClash source")
    if "if '${8}' == '1' and ['url-test', 'load-balance'].include?(group['type']) then" not in rules_text:
        raise AssertionError("OpenClash native auto_smart_switch group conversion is missing")
    if "ulimit -v unlimited && %s -v" not in controller_text:
        raise AssertionError("LuCI Smart Core version probe is still under the 1 GiB VMA limit")
    yml_change = source_root / "luci-app-openclash/root/usr/share/openclash/yml_change.sh"
    if "SMART_POLICY_REWRITE=APPLIED" in yml_change.read_text(encoding="utf-8"):
        raise AssertionError("obsolete single-group Smart YAML rewrite remains in prepared source")

    shell = shutil.which("sh") or shutil.which("bash")
    if not shell and sys.platform == "win32":
        for candidate in (Path("C:/Program Files/Git/usr/bin/sh.exe"), Path("C:/Program Files/Git/bin/bash.exe")):
            if candidate.is_file():
                shell = str(candidate)
                break
    if shell:
        parsed = subprocess.run([shell, "-n", str(init)], capture_output=True, text=True, check=False)
        if parsed.returncode:
            raise AssertionError(f"official OpenClash init script has invalid shell syntax:\n{parsed.stdout}")


def main() -> int:
    hook = HOOK.read_text(encoding="utf-8")
    build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    if "0015-smart-core-luci-vm-limit.patch" not in hook:
        raise AssertionError("LuCI Smart Core VMA-limit patch is not wired into the build")
    if 'git -C "$SOURCES/OpenClash" apply "$CORE_VM_PATCH"' not in hook:
        raise AssertionError("LuCI Smart Core VMA-limit patch is not applied to OpenClash")
    if "0015-smart-auto-select-policy.patch" in hook or "SMART_POLICY_PATCH" in hook:
        raise AssertionError("obsolete one-group Smart YAML patch remains wired into the build")
    if 'OPENCLASH_NATIVE_SOURCE_ROOT="$SRC/.xinzhao-sources/OpenClash"' not in build:
        raise AssertionError("prepared native OpenClash source is not included in the build verification")
    if "0014-smart-core-bundle-and-runtime-selection.patch" in hook:
        raise AssertionError("legacy Smart Core init patch is still wired into the build")
    if (ROOT / "files/usr/libexec/xinzhao-openclash-core-select").exists():
        raise AssertionError("legacy selector must not be shipped")

    defaults = DEFAULTS.read_text(encoding="utf-8")
    for marker in (
        "uci -q set openclash.config.smart_enable='1'",
        "uci -q set openclash.config.core_type='Smart'",
        "uci -q set openclash.config.auto_smart_switch='1'",
        "clash-verge/v2.4.5",
    ):
        if marker not in defaults:
            raise AssertionError(f"native OpenClash default is missing: {marker}")

    check_prepared_source()
    print("OPENCLASH_SMART_CORE_NATIVE_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
