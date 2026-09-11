#!/usr/bin/env python3
"""Run the real LuCI legacy Lua template parser and execute QuickStart."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


LUA = r'''
local parser = require "luci.template.parser"
local home = assert(arg[1], "home template missing")
local main = assert(arg[2], "main template missing")
local home_fn, _, home_err = parser.parse(home)
assert(home_fn, home_err or "home parse failed")
local main_fn, _, main_err = parser.parse(main)
assert(main_fn, main_err or "main parse failed")

local output = {}
local function write(value) output[#output + 1] = tostring(value or "") end
local fake_uci = { get = function() return nil end, get_first = function() return nil end }
local env = {
  write = write,
  token = "template-smoke-token",
  prefix = "/cgi-bin/luci/admin/quickstart",
  lang = "en",
  require = require,
  include = function() end,
}
env.luci = {
  dispatcher = { build_url = function() return env.prefix end },
  i18n = { translate = function(key) if key == "quickstart_vue_lang" then return "en" end return key end },
  sys = { call = function() return 1 end },
  jsonc = { stringify = function() return "[]" end },
  template = {},
}
package.preload["luci.jsonc"] = function() return env.luci.jsonc end
package.preload["luci.model.uci"] = function() return { cursor = function() return fake_uci end } end
env.luci.template.render = function(name, scope)
  assert(name == "quickstart/main", "unexpected nested template: " .. tostring(name))
  local child = setmetatable(scope or {}, { __index = env })
  setfenv(main_fn, child)
  assert(pcall(main_fn))
end
setfenv(home_fn, setmetatable(env, { __index = _G }))
assert(pcall(home_fn))
local rendered = table.concat(output)
assert(rendered:find('<div id="app">', 1, true), "QuickStart app mount missing")
assert(rendered:find("/luci-static/quickstart/index.js", 1, true), "QuickStart JS missing")
assert(rendered:find("/luci-static/quickstart/style.css", 1, true), "QuickStart CSS missing")
print("LUCI_TEMPLATE_PARSE=PASS")
print("LUCI_TEMPLATE_RENDER=PASS")
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    rootfs = Path(args.rootfs).resolve()
    if not Path(args.config).is_file():
        raise SystemExit("FAIL: full config missing")
    home = rootfs / "usr/lib/lua/luci/view/quickstart/home.htm"
    main_template = rootfs / "usr/lib/lua/luci/view/quickstart/main.htm"
    for path in (home, main_template):
        if not path.is_file():
            raise SystemExit(f"FAIL: final rootfs template missing: {path}")

    runners: list[tuple[str, list[str], dict[str, str]]] = []
    for name in ("lua", "luajit"):
        found = shutil.which(name)
        if found:
            runners.append((name, [found], {}))
    for name in ("qemu-aarch64-static", "qemu-aarch64"):
        found = shutil.which(name)
        if found and (rootfs / "usr/bin/lua").is_file():
            runners.append((name, [found, str(rootfs / "usr/bin/lua")], {"QEMU_LD_PREFIX": str(rootfs)}))
    if not runners:
        raise SystemExit("FAIL: no Lua/LuaJIT or aarch64 Lua runtime is available for actual LuCI parser validation")

    lua_path = ";".join(str(p) for p in (rootfs / "usr/lib/lua").glob("?.lua"))
    env = os.environ.copy()
    env["LUA_PATH"] = f"{rootfs}/usr/lib/lua/?.lua;{rootfs}/usr/lib/lua/?/init.lua;{rootfs}/usr/lib/lua/5.1/?.lua;{rootfs}/usr/lib/lua/5.1/?/init.lua;;"
    env["LUA_CPATH"] = f"{rootfs}/usr/lib/lua/?.so;{rootfs}/usr/lib/lua/5.1/?.so;;"
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(LUA)
        harness = handle.name
    try:
        for runner_name, command, extra in runners:
            run_env = env | extra
            result = subprocess.run(command + [harness, str(home), str(main_template)], env=run_env, text=True, capture_output=True, check=False)
            if result.returncode == 0:
                print(result.stdout, end="")
                return 0
            last = f"{runner_name}: {result.stdout}{result.stderr}"
        raise SystemExit(f"FAIL: actual LuCI legacy template parse/render failed\n{last}")
    finally:
        Path(harness).unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
