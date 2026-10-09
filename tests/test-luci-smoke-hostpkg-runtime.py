#!/usr/bin/env python3
"""Check discovery of ImmortalWrt package-host Lua executables."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SMOKE_PATH = ROOT / "scripts/luci-legacy-template-smoke.py"
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
    assert (f"host-{host_lua.name}", [str(host_lua)], {}) in runners, (
        "staging_dir/hostpkg/bin/lua must be discovered"
    )

print("QUICKSTART_HOSTPKG_LUA_DISCOVERY=PASS")
