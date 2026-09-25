#!/usr/bin/env python3
"""Verify official OpenClash cores and the unmodified native runtime path."""
from __future__ import annotations

import argparse
import hashlib
import json
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
    return {
        line.split()[0]
        for line in read(path, "firmware package manifest").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def verify_elf(data: bytes, label: str) -> None:
    require(len(data) >= 20 and data[:4] == b"\x7fELF", f"{label} is not an ELF executable")
    require(data[4] == 2 and data[5] == 1, f"{label} is not little-endian ELF64")
    require(struct.unpack("<H", data[18:20])[0] == 183, f"{label} is not AArch64")


def verify_core(lock: dict, staged: Path, final: Path, label: str) -> tuple[bytes, str]:
    require(staged.is_file(), f"staged {label} Core is missing: {staged}")
    require(final.is_file(), f"final {label} Core is missing: {final}")
    staged_data = staged.read_bytes()
    final_data = final.read_bytes()
    require(final_data == staged_data, f"final {label} Core differs from the staged payload")
    verify_elf(final_data, f"final {label} Core")
    if sys.platform != "win32":
        require(final.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH), f"final {label} Core is not executable")
    digest = hashlib.sha256(final_data).hexdigest()
    if label == "Smart":
        sidecar = staged.with_suffix(".sha256")
        final_sidecar = final.with_suffix(".sha256")
        require(sidecar.is_file() and final_sidecar.is_file(), "Smart Core SHA-256 sidecar is missing")
        require(sidecar.read_text(encoding="ascii").strip() == digest, "staged Smart Core SHA-256 sidecar is wrong")
        require(final_sidecar.read_text(encoding="ascii").strip() == digest, "final Smart Core SHA-256 sidecar is wrong")
    return final_data, digest


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
    require(lock.get("source_repository") == "vernesong/OpenClash", "Meta Core lock is not official")
    require(smart_lock.get("source_repository") == "vernesong/OpenClash", "Smart Core lock is not official")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("source_ref", ""))), "Meta Core lock is not immutable")
    require(smart_lock.get("source_ref") == lock.get("source_ref"), "Meta and Smart Core refs differ")
    require(smart_lock.get("asset_path") == "master/smart/clash-linux-arm64.tar.gz", "Smart Core asset path is invalid")
    for item in (lock, smart_lock):
        require(re.fullmatch(r"[0-9a-f]{40}", str(item.get("asset_git_blob_sha1", ""))), "Core archive pin is invalid")

    installed = packages(args.package_manifest)
    require({"luci-app-openclash", "openclash-core"} <= installed, "OpenClash package set is incomplete")

    staged_meta = source_root / "package/xinzhao/openclash-core/files/clash_meta"
    staged_smart = source_root / "package/xinzhao/openclash-core/files/clash_smart"
    final_meta = rootfs / "etc/openclash/core/clash_meta"
    final_smart = rootfs / "etc/openclash/core/clash_smart"
    meta_data, meta_digest = verify_core(lock, staged_meta, final_meta, "Meta")
    smart_data, smart_digest = verify_core(smart_lock, staged_smart, final_smart, "Smart")

    archives = list((source_root / "bin").rglob("openclash-core_*.ipk")) + list((source_root / "bin").rglob("openclash-core-*.apk"))
    require(archives, "compiled openclash-core package archive is missing")

    init = read(source_root / ".xinzhao-sources/OpenClash/luci-app-openclash/root/etc/init.d/openclash", "OpenClash native init")
    for marker in (
        'meta_core_path="/etc/openclash/core/clash_meta"',
        'ln -s "$meta_core_path" /etc/openclash/clash',
        'change_dnsmasq "$enable_redirect_dns"',
        "set_firewall",
        'openclash_core.sh "$core_type"',
    ):
        require(marker in init, f"native OpenClash init contract is missing: {marker}")
    require("/usr/libexec/xinzhao-openclash-core-select" not in init, "legacy Smart Core selector is still wired into init")

    updater = read(source_root / ".xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_core.sh", "OpenClash native Core updater")
    require("CORE_TYPE=\"$1\"" in updater, "native Core updater is missing its Core type input")
    require("RELEASE_BRANCH/smart" in updater, "native Smart Core download path is missing")

    defaults = read(rootfs / "etc/uci-defaults/95-xinzhao-openclash-defaults", "OpenClash first-boot defaults")
    require("uci -q set openclash.config.smart_enable='1'" in defaults, "Smart Core is not enabled through native UCI defaults")
    require("uci -q set openclash.config.core_type='Smart'" in defaults, "native UCI Smart core type default is missing")
    require("clash-verge/v2.4.5" in defaults, "official subscription User-Agent default is missing")
    require(not (rootfs / "usr/libexec/xinzhao-openclash-core-select").exists(), "legacy selector is present in final rootfs")

    config = read(rootfs / "etc/config/openclash", "OpenClash UCI config")
    require(re.search(r"(?m)^\s*option small_flash_memory '0'\s*$", config) is not None, "OpenClash volatile Core default changed")

    emit = [
        f"OPENCLASH_CORE_VERSION={lock['core_version']}",
        f"OPENCLASH_CORE_SHA256={meta_digest}",
        "OPENCLASH_APK_ARCHIVE_PATTERN=PASS",
        "OPENCLASH_CORE_BUNDLED=PASS",
        "OPENCLASH_CORE_ARCH=PASS",
        "OPENCLASH_META_CORE_ARCH_VALUE=aarch64/linux-arm64",
        "OPENCLASH_CORE_EXECUTABLE=PASS",
        "OPENCLASH_NATIVE_RUNTIME=PASS",
        "OPENCLASH_NATIVE_SMART_DEFAULT=PASS",
        "META_CORE_INCLUDED=PASS",
        "SMART_CORE_INCLUDED=PASS",
        "SMART_CORE_ARCH=PASS",
        "SMART_CORE_ARCH_VALUE=aarch64/linux-arm64",
        "SMART_CORE_EXECUTABLE=PASS",
        f"META_CORE_SHA256={meta_digest}",
        f"SMART_CORE_SHA256_VALUE={smart_digest}",
        "SMART_CORE_SHA256=PASS",
        "SMART_CORE_SELECTOR_INCLUDED=ABSENT",
    ]
    print("\n".join(emit))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"FINAL_ROOTFS_OPENCLASH_CORE=FAIL -- {exc}", file=sys.stderr)
        raise SystemExit(1)
