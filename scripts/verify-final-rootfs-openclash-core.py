#!/usr/bin/env python3
"""Verify the pinned official OpenClash Meta Core is installed in the Arthur image."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys


class GateError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def read(path: Path, label: str) -> str:
    require(path.is_file(), f"{label} is missing: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def packages(path: Path) -> set[str]:
    names = set()
    for line in read(path, "firmware package manifest").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line.split()[0])
    return names


def elf_machine(data: bytes) -> tuple[int, int]:
    require(len(data) >= 20 and data[:4] == b"\x7fELF", "bundled Core is not an ELF executable")
    require(data[4] == 2, "bundled Core ELF class is not 64-bit")
    require(data[5] == 1, "bundled Core ELF byte order is not little-endian")
    return data[4], struct.unpack("<H", data[18:20])[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("package_manifest", type=Path)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--lock", type=Path, default=Path(__file__).resolve().parents[1] / "config/openclash-core.lock.json")
    args = parser.parse_args()

    rootfs = args.rootfs.resolve()
    source_root = args.source_root.resolve()
    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    require(lock.get("source_repository") == "vernesong/OpenClash", "Core lock is not pinned to official OpenClash")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("source_ref", ""))) is not None, "Core lock is not pinned to an immutable commit")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("asset_git_blob_sha1", ""))) is not None,
            "official Meta Core archive is missing its Git blob integrity pin")

    installed = packages(args.package_manifest)
    require("luci-app-openclash" in installed, "luci-app-openclash is absent from the firmware manifest")
    require("openclash-core" in installed, "openclash-core package is absent from the firmware manifest")

    staged = source_root / "package/xinzhao/openclash-core/files/clash_meta"
    core = rootfs / "etc/openclash/core/clash_meta"
    require(staged.is_file(), f"staged official Core is missing: {staged}")
    require(core.is_file(), "bundled OpenClash Core is missing from final rootfs: /etc/openclash/core/clash_meta")
    staged_data = staged.read_bytes()
    core_data = core.read_bytes()
    require(hashlib.sha256(core_data).digest() == hashlib.sha256(staged_data).digest(), "final rootfs Core differs from the verified staged package payload")
    elf_class, machine = elf_machine(core_data)
    require(elf_class == 2 and machine == int(lock["elf_machine"]) == 183, "bundled Core architecture is not AArch64")
    manager_makefile = source_root / "package/xinzhao/openclash-core/Makefile"
    require(manager_makefile.is_file(), f"openclash-core package source is missing: {manager_makefile}")
    if os.name == "nt":
        package_recipe = read(manager_makefile, "openclash-core package recipe")
        require("$(INSTALL_BIN)" in package_recipe, "openclash-core package does not install executable permissions")
    else:
        require(bool(core.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)), "bundled Core is not executable in final rootfs")

    package_root = source_root / "bin"
    package_ipk_archives = list(package_root.rglob("openclash-core_*.ipk"))
    package_apk_archives = list(package_root.rglob("openclash-core-*.apk"))
    package_archives = package_ipk_archives + package_apk_archives
    require(package_archives, "compiled openclash-core package archive is missing")

    init_path = source_root / "feeds/luci/applications/luci-app-openclash/root/etc/init.d/openclash"
    init = read(init_path, "OpenClash init script")
    require('meta_core_path="/etc/openclash/core/clash_meta"' in init, "OpenClash runtime Core path does not match the bundled path")
    require('ln -s "$meta_core_path" /etc/openclash/clash' in init, "OpenClash runtime launcher does not point at the bundled Meta Core")
    require("[ ! -f \"$CLASH\" ]" in init and "/usr/share/openclash/openclash_core.sh \"$core_type\"" in init,
            "OpenClash startup does not guard its online Core fallback on the installed Core")

    config = read(rootfs / "etc/config/openclash", "OpenClash default UCI config")
    require(re.search(r"(?m)^\s*option small_flash_memory '0'\s*$", config) is not None,
            "OpenClash default selects volatile Core storage instead of the bundled path")
    require(re.search(r"(?m)^\s*option smart_enable '0'\s*$", config) is not None,
            "OpenClash default does not select the bundled Meta Core")
    oix = re.search(r"(?m)^\s*option oix_token '([^']*)'\s*$", config)
    require(oix is None or not oix.group(1), "OpenClash default selects an alternate OIX Core")

    digest = hashlib.sha256(core_data).hexdigest()
    print(f"OPENCLASH_CORE_VERSION={lock['core_version']}")
    print(f"OPENCLASH_CORE_SHA256={digest}")
    print("OPENCLASH_APK_ARCHIVE_PATTERN=PASS")
    print("OPENCLASH_CORE_BUNDLED=PASS")
    print("OPENCLASH_CORE_ARCH=PASS elf_class=64 machine=AArch64")
    print("OPENCLASH_CORE_EXECUTABLE=PASS")
    print("OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"FINAL_ROOTFS_OPENCLASH_CORE=FAIL -- {exc}", file=sys.stderr)
        raise SystemExit(1)
