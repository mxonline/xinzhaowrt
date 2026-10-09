#!/usr/bin/env python3
"""Check discovery of ImmortalWrt package-host Lua executables."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SMOKE_PATH = ROOT / "scripts/luci-legacy-template-smoke.py"
SETUP_PATH = ROOT / "scripts/codex-setup.sh"
SPEC = importlib.util.spec_from_file_location("luci_legacy_template_smoke", SMOKE_PATH)
assert SPEC is not None and SPEC.loader is not None
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)

discover = getattr(SMOKE, "discover_lua_runners", None)
assert callable(discover), "Lua runtime discovery must be directly testable"

with tempfile.TemporaryDirectory() as temp_dir:
    root = Path(temp_dir)
    source_root = root / "source"
    rootfs = root / "rootfs"
    host_lua = source_root / "staging_dir/hostpkg/bin/lua"
    host_lua.parent.mkdir(parents=True)
    host_lua.write_bytes(b"host runtime placeholder")
    os.chmod(host_lua, 0o755)
    (root / "empty-path").mkdir()

    runners = discover(source_root, rootfs, search_path=str(root / "empty-path"))
    assert runners == [], (
        "host Lua must not be used with target-architecture rootfs modules"
    )

with tempfile.TemporaryDirectory() as temp_dir:
    root = Path(temp_dir)
    source_root = root / "source"
    rootfs = root / "rootfs"
    host_lua = source_root / "staging_dir/hostpkg/bin/lua5.1"
    host_lua.parent.mkdir(parents=True)
    host_lua.write_bytes(b"host runtime placeholder")
    os.chmod(host_lua, 0o755)

    target_lua = rootfs / "usr/bin/lua"
    target_lua.parent.mkdir(parents=True)
    target_lua.write_bytes(b"target runtime placeholder")
    os.chmod(target_lua, 0o755)

    qemu_dir = root / "qemu-bin"
    qemu_dir.mkdir()
    qemu_name = "qemu-aarch64-static.exe" if os.name == "nt" else "qemu-aarch64-static"
    qemu = qemu_dir / qemu_name
    qemu.write_bytes(b"qemu placeholder")
    os.chmod(qemu, 0o755)

    runners = discover(source_root, rootfs, search_path=str(qemu_dir))
    assert len(runners) == 1 and runners[0][0] == "qemu-aarch64-static", (
        "target Lua under qemu must be used without falling back to host Lua"
    )
    runner_name, command, environment = runners[0]
    assert Path(command[0]).name.casefold() == qemu.name.casefold()
    assert command[1] == str(target_lua)
    assert environment == {"QEMU_LD_PREFIX": str(rootfs)}

assert "qemu-user-static" in SETUP_PATH.read_text(encoding="utf-8"), (
    "production build dependencies must install the QEMU user-mode runner"
)

print("QUICKSTART_HOST_LUA_REJECTED=PASS")
print("QUICKSTART_TARGET_QEMU_PREFERRED=PASS")
