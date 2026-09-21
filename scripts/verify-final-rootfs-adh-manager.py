#!/usr/bin/env python3
"""Fail the firmware build unless the accepted full AdGuard Home manager is installed."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


ROOT = Path(__file__).resolve().parents[1]
MANAGER_PREFIXES = (
    "files/etc/AdGuardHome.yaml",
    "files/etc/config/AdGuardHome",
    "files/etc/init.d/AdGuardHome",
    "files/usr/lib/lua/luci/controller/AdGuardHome.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/",
    "files/usr/lib/lua/luci/view/AdGuardHome/",
    "files/usr/share/AdGuardHome/",
    "files/usr/share/luci/menu.d/luci-app-adguardhome.json",
    "files/usr/share/rpcd/acl.d/luci-app-adguardhome.json",
    "files/www/luci-static/resources/adguardhome/",
    "files/www/luci-static/resources/view/luci-app-adguardhome/",
)
REQUIRED_OVERLAYS = (
    "files/etc/AdGuardHome.yaml",
    "files/etc/config/AdGuardHome",
    "files/etc/init.d/AdGuardHome",
    "files/usr/lib/lua/luci/controller/AdGuardHome.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/overview.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/tools.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/log.lua",
    "files/usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua",
    "files/usr/lib/lua/luci/view/AdGuardHome/overview.htm",
    "files/usr/share/luci/menu.d/luci-app-adguardhome.json",
    "files/usr/share/rpcd/acl.d/luci-app-adguardhome.json",
    "files/usr/share/AdGuardHome/AdGuardHome_template.yaml",
)


class GateError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def package_names(manifest_path: Path) -> set[str]:
    names: set[str] = set()
    for raw in manifest_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            names.add(line.split()[0])
    return names


def package_dependencies(makefile: Path) -> set[str]:
    dependencies: set[str] = set()
    for line in makefile.read_text(encoding="utf-8", errors="replace").splitlines():
        if re.match(r"\s*(?:DEPENDS|LUCI_DEPENDS|LUCI_EXTRA_DEPENDS)\s*[:+?]?=", line):
            dependencies.update(re.findall(r"\+([A-Za-z0-9_.+-]+)", line))
            extra = re.match(r"\s*LUCI_EXTRA_DEPENDS\s*[:+?]?=\s*([A-Za-z0-9_.+-]+)", line)
            if extra:
                dependencies.add(extra.group(1))
    return dependencies


def read_text(rootfs: Path, relative: str) -> str:
    path = rootfs / relative
    require(path.is_file(), f"rootfs file missing: /{relative}")
    return path.read_text(encoding="utf-8", errors="replace")


def check_accepted_overlay_hashes(rootfs: Path, accepted_path: Path) -> int:
    accepted = json.loads(accepted_path.read_text(encoding="utf-8"))
    entries = [
        item for item in accepted.get("frozen_files", [])
        if any(item.get("overlay", "").startswith(prefix) for prefix in MANAGER_PREFIXES)
    ]
    by_overlay = {item["overlay"]: item for item in entries}
    missing_contract = sorted(set(REQUIRED_OVERLAYS) - set(by_overlay))
    require(not missing_contract, f"accepted manager manifest is incomplete: {', '.join(missing_contract)}")

    for overlay, item in by_overlay.items():
        target = rootfs / Path(overlay).relative_to("files")
        require(target.is_file(), f"accepted manager rootfs file missing: /{target.relative_to(rootfs)}")
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        require(digest == item.get("sha256"), f"accepted manager hash mismatch: /{target.relative_to(rootfs)}")
    return len(entries)


def check_acl(acl: dict) -> None:
    group = acl.get("luci-app-adguardhome")
    require(isinstance(group, dict), "rpcd ACL group luci-app-adguardhome is missing")
    read = group.get("read", {})
    write = group.get("write", {})
    require("AdGuardHome" in read.get("uci", []), "rpcd ACL read access to AdGuardHome UCI is missing")
    require("AdGuardHome" in write.get("uci", []), "rpcd ACL write access to AdGuardHome UCI is missing")
    require("getInitList" in read.get("ubus", {}).get("luci", []), "rpcd ACL init status permission is missing")
    require("setInitAction" in write.get("ubus", {}).get("luci", []), "rpcd ACL lifecycle permission is missing")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("package_manifest", type=Path)
    parser.add_argument("package_makefile", type=Path)
    parser.add_argument("manager_makefile", type=Path)
    parser.add_argument("source_root", type=Path)
    parser.add_argument(
        "--accepted-manifest",
        type=Path,
        default=ROOT / "production/accepted-preview/arthur-adh-quickstart.json",
    )
    args = parser.parse_args()

    rootfs = args.rootfs.resolve()
    require(rootfs.is_dir(), f"final rootfs directory missing: {rootfs}")
    require(args.package_manifest.is_file(), f"final package manifest missing: {args.package_manifest}")
    require(args.package_makefile.is_file(), f"luci-app-adguardhome package source missing: {args.package_makefile}")
    require(args.manager_makefile.is_file(), f"full manager package source missing: {args.manager_makefile}")

    installed = package_names(args.package_manifest)
    require("luci-app-adguardhome" in installed, "luci-app-adguardhome is absent from the firmware manifest")
    require("luci-app-adguardhome-manager" in installed, "full AdGuard Home manager package is absent from the firmware manifest")
    dependencies = package_dependencies(args.package_makefile) | package_dependencies(args.manager_makefile)
    require(dependencies, "luci-app-adguardhome declares no required dependencies")
    missing_dependencies = sorted(dependencies - installed)
    require(not missing_dependencies, f"required ADH dependencies absent from firmware manifest: {', '.join(missing_dependencies)}")
    required_runtime = {"adguardhome", "luci-base", "luci-compat", "rpcd-mod-file"}
    missing_runtime = sorted(required_runtime - installed)
    require(not missing_runtime, f"required ADH runtime packages absent from firmware manifest: {', '.join(missing_runtime)}")
    package_root = args.source_root.resolve().joinpath("bin")
    manager_ipk_archives = list(package_root.rglob("luci-app-adguardhome-manager_*.ipk"))
    manager_apk_archives = list(package_root.rglob("luci-app-adguardhome-manager-*.apk"))
    manager_archives = manager_ipk_archives + manager_apk_archives
    require(manager_archives, "compiled full manager package archive is missing")

    count = check_accepted_overlay_hashes(rootfs, args.accepted_manifest)
    menu_path = rootfs / "usr/share/luci/menu.d/luci-app-adguardhome.json"
    acl_path = rootfs / "usr/share/rpcd/acl.d/luci-app-adguardhome.json"
    try:
        menu = json.loads(menu_path.read_text(encoding="utf-8"))
        acl = json.loads(acl_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GateError(f"AdGuard Home menu/ACL JSON is invalid: {exc}") from exc

    for route in ("overview", "base", "tools", "log", "manual"):
        item = menu.get(f"admin/services/AdGuardHome/{route}")
        require(isinstance(item, dict), f"full manager LuCI route is missing: {route}")
    require("admin/services/adguardhome" not in menu, "upstream basic SPA route replaced the full manager")
    check_acl(acl)

    controller = read_text(rootfs, "usr/lib/lua/luci/controller/AdGuardHome.lua")
    overview = read_text(rootfs, "usr/lib/lua/luci/view/AdGuardHome/overview.htm")
    init_path = rootfs / "etc/init.d/AdGuardHome"
    init = read_text(rootfs, "etc/init.d/AdGuardHome")
    uci = read_text(rootfs, "etc/config/AdGuardHome")
    require("function service_action()" in controller, "manager lifecycle controller is missing")
    for action in ("start", "stop", "restart", "enable", "disable"):
        require(f'{action} = "{action}"' in controller, f"lifecycle controller action missing: {action}")
        require(f'data-adg-action="{action}"' in overview, f"lifecycle UI button missing: {action}")
    require("start_service()" in init and "stop_service()" in init, "AdGuard Home init lifecycle functions are missing")
    if os.name == "nt":
        accepted = json.loads(args.accepted_manifest.read_text(encoding="utf-8"))
        init_entry = next(item for item in accepted["frozen_files"] if item.get("overlay") == "files/etc/init.d/AdGuardHome")
        require(bool(int(init_entry["mode"], 8) & 0o111), "accepted AdGuard Home init source is not executable")
    else:
        require(bool(init_path.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)), "AdGuard Home init script is not executable")
    require(re.search(r"(?m)^\s*option enabled '0'\s*$", uci) is not None, "ADH default state is not disabled")
    require(re.search(r"(?m)^\s*option httpport '3000'\s*$", uci) is not None, "ADH Web UI default port is missing")
    require("AdGuardHome_template.yaml" in {p.name for p in (rootfs / "usr/share/AdGuardHome").glob("*")}, "AdGuard Home template is missing")

    print(f"ADH_ACCEPTED_MANAGER_FILES={count}")
    print("ADH_APK_ARCHIVE_PATTERN=PASS")
    print("ADH_PACKAGE_MANIFEST=PASS")
    print("ADH_LUCI_MANAGER_PACKAGE=PASS")
    print("ADH_REQUIRED_DEPENDENCIES=PASS packages=" + ",".join(sorted(dependencies)))
    print("ADH_LUCI_FULL_MANAGER=PASS")
    print("ADH_LIFECYCLE_START_STOP_RESTART=PASS")
    print("ADH_ENABLE_DISABLE=PASS")
    print("ADH_WEB_UI=PASS")
    print("ADH_DEFAULT_STATE=DISABLED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, json.JSONDecodeError) as exc:
        print(f"FINAL_ROOTFS_ADH_MANAGER=FAIL -- {exc}", file=sys.stderr)
        raise SystemExit(1)
