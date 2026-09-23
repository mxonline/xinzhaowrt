#!/usr/bin/env python3
"""Verify both pinned official OpenClash Cores are installed in the Arthur image."""
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


def emit_marker(name: str, verified: bool) -> None:
    print(f"{name}={'PASS' if verified else 'FAIL'}")


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
    parser.add_argument("--smart-lock", type=Path, default=Path(__file__).resolve().parents[1] / "config/openclash-smart-core.lock.json")
    args = parser.parse_args()

    rootfs = args.rootfs.resolve()
    source_root = args.source_root.resolve()
    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    smart_lock = json.loads(args.smart_lock.read_text(encoding="utf-8"))
    require(lock.get("source_repository") == "vernesong/OpenClash", "Core lock is not pinned to official OpenClash")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("source_ref", ""))) is not None, "Core lock is not pinned to an immutable commit")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("asset_git_blob_sha1", ""))) is not None,
            "official Meta Core archive is missing its Git blob integrity pin")
    require(smart_lock.get("source_repository") == "vernesong/OpenClash", "Smart Core lock is not pinned to official OpenClash")
    require(smart_lock.get("source_ref") == lock.get("source_ref"), "Meta and Smart Core must share the reviewed immutable source ref")
    require(smart_lock.get("core_type") == "Smart", "Smart Core lock does not identify Smart Core")
    require(smart_lock.get("asset_path") == "master/smart/clash-linux-arm64.tar.gz", "Smart Core asset path is invalid")
    require(re.fullmatch(r"[0-9a-f]{40}", str(smart_lock.get("asset_git_blob_sha1", ""))) is not None,
            "official Smart Core archive is missing its Git blob integrity pin")

    installed = packages(args.package_manifest)
    require("luci-app-openclash" in installed, "luci-app-openclash is absent from the firmware manifest")
    require("openclash-core" in installed, "openclash-core package is absent from the firmware manifest")

    staged = source_root / "package/xinzhao/openclash-core/files/clash_meta"
    core = rootfs / "etc/openclash/core/clash_meta"
    require(staged.is_file(), f"staged official Core is missing: {staged}")
    meta_core_present = core.is_file()
    require(meta_core_present, "bundled OpenClash Core is missing from final rootfs: /etc/openclash/core/clash_meta")
    staged_data = staged.read_bytes()
    core_data = core.read_bytes()
    require(hashlib.sha256(core_data).digest() == hashlib.sha256(staged_data).digest(), "final rootfs Core differs from the verified staged package payload")
    elf_class, machine = elf_machine(core_data)
    meta_arch = "aarch64/linux-arm64" if elf_class == 2 and machine == int(lock["elf_machine"]) == 183 else f"elf-class-{elf_class}-machine-{machine}"
    require(meta_arch == "aarch64/linux-arm64", "bundled Core architecture is not AArch64")
    manager_makefile = source_root / "package/xinzhao/openclash-core/Makefile"
    require(manager_makefile.is_file(), f"openclash-core package source is missing: {manager_makefile}")
    meta_executable = bool(core.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
    if os.name != "nt":
        require(meta_executable, "bundled Core is not executable in final rootfs")

    staged_smart = source_root / "package/xinzhao/openclash-core/files/clash_smart"
    staged_smart_sha = source_root / "package/xinzhao/openclash-core/files/clash_smart.sha256"
    smart_core = rootfs / "etc/openclash/core/clash_smart"
    smart_sha = rootfs / "etc/openclash/core/clash_smart.sha256"
    require(staged_smart.is_file() and staged_smart_sha.is_file(), "verified Smart Core staging payload or SHA pin is missing")
    smart_core_included = smart_core.is_file() and smart_sha.is_file()
    require(smart_core_included, "bundled Smart Core or SHA pin is missing from final rootfs")
    staged_smart_data = staged_smart.read_bytes()
    smart_data = smart_core.read_bytes()
    expected_smart_digest = hashlib.sha256(staged_smart_data).hexdigest()
    smart_core_included = smart_core_included and smart_data == staged_smart_data
    require(smart_core_included, "final rootfs Smart Core differs from the verified staged payload")
    smart_sha_verified = staged_smart_sha.read_text(encoding="ascii").strip() == expected_smart_digest
    require(smart_sha_verified,
            "staged Smart Core SHA-256 sidecar does not match the verified binary")
    smart_sha_verified = smart_sha_verified and smart_sha.read_text(encoding="ascii").strip() == expected_smart_digest
    require(smart_sha_verified,
            "final rootfs Smart Core SHA-256 sidecar does not match the verified binary")
    smart_elf_class, smart_machine = elf_machine(smart_data)
    smart_arch = "aarch64/linux-arm64" if smart_elf_class == 2 and smart_machine == int(smart_lock["elf_machine"]) == 183 else f"elf-class-{smart_elf_class}-machine-{smart_machine}"
    require(smart_arch == "aarch64/linux-arm64",
            "bundled Smart Core architecture is not AArch64")
    smart_executable = bool(smart_core.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
    if os.name != "nt":
        require(smart_executable, "bundled Smart Core is not executable in final rootfs")

    package_root = source_root / "bin"
    package_ipk_archives = list(package_root.rglob("openclash-core_*.ipk"))
    package_apk_archives = list(package_root.rglob("openclash-core-*.apk"))
    package_archives = package_ipk_archives + package_apk_archives
    require(package_archives, "compiled openclash-core package archive is missing")

    init_path = source_root / "feeds/luci/applications/luci-app-openclash/root/etc/init.d/openclash"
    init = read(init_path, "OpenClash init script")
    require('meta_core_path="/etc/openclash/core/clash_meta"' in init, "OpenClash Meta Core path does not match the bundled path")
    require('/usr/libexec/xinzhao-openclash-core-select' in init, "OpenClash startup does not select Core from the active config")
    require('if [ "$core_type" = "Smart" ]; then' in init, "OpenClash startup does not explicitly select Smart Core")
    require('meta_core_path="$smart_core_path"' in init, "OpenClash launcher path is not switched to the selected Smart Core")
    require("SMART_CORE_SELECTED=PASS" in init and "OPENCLASH_SMART_START=PASS" in init and "SMART_CONFIG_PARSE=PASS" in init,
            "OpenClash startup does not emit Smart Core selection/parse/start evidence")
    require('[ "$core_type" != "Smart" ]' in init,
            "Smart Core startup can enter the online Core fallback path")
    updater = source_root / "feeds/luci/applications/luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
    updater_text = read(updater, "OpenClash Core updater")
    require('Pinned firmware Smart Core is immutable' in updater_text,
            "manual Smart Core update can overwrite the pinned bundled Core or Meta Core")
    selector = source_root / "files/usr/libexec/xinzhao-openclash-core-select"
    selector_text = read(selector, "Arthur OpenClash core selector")
    require("type:" in selector_text and "sha256sum" in selector_text and "refusing Meta fallback" in selector_text,
            "Smart Core selector does not detect Smart YAML and fail closed on a hash mismatch")
    rootfs_selector = rootfs / "usr/libexec/xinzhao-openclash-core-select"
    selector_included = rootfs_selector.is_file()
    require(selector_included, "Smart Core selector is missing from final rootfs")
    selector_included = selector_included and rootfs_selector.read_bytes() == selector.read_bytes()
    require(selector_included,
            "final rootfs Smart Core selector differs from the verified source selector")
    selector_executable = bool(rootfs_selector.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
    if os.name != "nt":
        require(selector_executable, "Smart Core selector is not executable in final rootfs")

    config = read(rootfs / "etc/config/openclash", "OpenClash default UCI config")
    require(re.search(r"(?m)^\s*option small_flash_memory '0'\s*$", config) is not None,
            "OpenClash default selects volatile Core storage instead of the bundled path")
    require(re.search(r"(?m)^\s*option smart_enable '0'\s*$", config) is not None,
            "OpenClash default does not select the bundled Meta Core")
    oix = re.search(r"(?m)^\s*option oix_token '([^']*)'\s*$", config)
    require(oix is None or not oix.group(1), "OpenClash default selects an alternate OIX Core")

    digest = hashlib.sha256(core_data).hexdigest()
    smart_digest = hashlib.sha256(smart_data).hexdigest()
    package_archive_pattern_verified = bool(package_archives)
    first_start_no_download_verified = (
        '/usr/libexec/xinzhao-openclash-core-select' in init
        and '[ "$core_type" != "Smart" ]' in init
        and selector_included
        and smart_core_included
    )
    print(f"OPENCLASH_CORE_VERSION={lock['core_version']}")
    print(f"OPENCLASH_CORE_SHA256={digest}")
    emit_marker("OPENCLASH_APK_ARCHIVE_PATTERN", package_archive_pattern_verified)
    emit_marker("OPENCLASH_CORE_BUNDLED", meta_core_present and hashlib.sha256(core_data).digest() == hashlib.sha256(staged_data).digest())
    print(f"OPENCLASH_META_CORE_ARCH_VALUE={meta_arch}")
    emit_marker("OPENCLASH_CORE_ARCH", meta_arch == "aarch64/linux-arm64")
    print(f"OPENCLASH_CORE_EXECUTABLE={'PASS' if meta_executable else 'UNVERIFIED' if os.name == 'nt' else 'FAIL'}")
    emit_marker("OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED", first_start_no_download_verified)
    emit_marker("META_CORE_INCLUDED", core.is_file() and hashlib.sha256(core_data).digest() == hashlib.sha256(staged_data).digest())
    emit_marker("SMART_CORE_INCLUDED", smart_core_included)
    emit_marker("SMART_CORE_ARCH", smart_arch == "aarch64/linux-arm64")
    print(f"SMART_CORE_ARCH_VALUE={smart_arch}")
    print(f"META_CORE_SHA256={digest}")
    print(f"SMART_CORE_EXECUTABLE={'PASS' if smart_executable else 'UNVERIFIED' if os.name == 'nt' else 'FAIL'}")
    print(f"SMART_CORE_SHA256_VALUE={smart_digest}")
    emit_marker("SMART_CORE_SHA256", smart_sha_verified and hashlib.sha256(smart_data).hexdigest() == expected_smart_digest)
    emit_marker("SMART_CORE_SELECTOR_INCLUDED", selector_included and (os.name == "nt" or bool(rootfs_selector.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))))
    print(f"SMART_CORE_SELECTOR_SHA256={hashlib.sha256(rootfs_selector.read_bytes()).hexdigest()}")
    print(f"SMART_CORE_SELECTOR_EXECUTABLE={'PASS' if selector_executable else 'UNVERIFIED' if os.name == 'nt' else 'FAIL'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"FINAL_ROOTFS_OPENCLASH_CORE=FAIL -- {exc}", file=sys.stderr)
        raise SystemExit(1)
