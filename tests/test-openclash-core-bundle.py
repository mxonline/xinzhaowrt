#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
STAGER = ROOT / "scripts/stage-openclash-core.py"
FINAL_VERIFIER = ROOT / "scripts/verify-final-rootfs-openclash-core.py"
SOURCE_LOCK = ROOT / "config/openclash-core.lock.json"


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def fake_aarch64_elf() -> bytes:
    image = bytearray(64)
    image[:4] = b"\x7fELF"
    image[4] = 2
    image[5] = 1
    image[6] = 1
    struct.pack_into("<H", image, 18, 183)
    return bytes(image)


def main() -> int:
    lock_source = json.loads(SOURCE_LOCK.read_text(encoding="utf-8"))
    if lock_source.get("source_repository") != "vernesong/OpenClash":
        raise AssertionError("Core source is not the official OpenClash repository")
    if lock_source.get("source_ref") != "dc71e38205fd2d83cc934592d3da8cf6da3e0b51":
        raise AssertionError("Core source must remain pinned to its reviewed immutable commit")
    if lock_source.get("asset_git_blob_sha1") != "5c90d325491032c316849c0ed39711a16dfdda4c":
        raise AssertionError("official arm64 Meta Core archive pin changed")
    if lock_source.get("core_version") != "alpha-ge183c58":
        raise AssertionError("official Meta Core version pin changed")
    arthur_config = (ROOT / "config/arthur.config").read_text(encoding="utf-8")
    if "CONFIG_PACKAGE_openclash-core=y" not in arthur_config:
        raise AssertionError("Arthur config does not install the Core package")
    package_recipe = (ROOT / "package/xinzhao/openclash-core/Makefile").read_text(encoding="utf-8")
    if "/etc/openclash/core/clash_meta" not in package_recipe or "$(INSTALL_BIN)" not in package_recipe:
        raise AssertionError("Core package does not install an executable at OpenClash's runtime path")
    build_script = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    if "fetch-openclash-core.sh" not in build_script or "verify-final-rootfs-openclash-core.py" not in build_script:
        raise AssertionError("Core fetch and final rootfs verification are not wired into the firmware build")

    with tempfile.TemporaryDirectory(prefix="openclash-core-stage-") as tmp_text:
        tmp = Path(tmp_text)
        archive = tmp / "core.tar.gz"
        core = fake_aarch64_elf()
        with tarfile.open(archive, "w:gz") as bundle:
            entry = tarfile.TarInfo("clash")
            entry.mode = 0o755
            entry.size = len(core)
            bundle.addfile(entry, __import__("io").BytesIO(core))
        archive_bytes = archive.read_bytes()

        lock = tmp / "lock.json"
        lock.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "source_repository": "vernesong/OpenClash",
                    "source_ref": "a" * 40,
                    "core_version": "alpha-g0123456",
                    "core_type": "Meta",
                    "asset_path": "master/meta/clash-linux-arm64.tar.gz",
                    "asset_size_bytes": len(archive_bytes),
                    "asset_git_blob_sha1": git_blob_sha1(archive_bytes),
                    "binary_name": "clash",
                    "install_path": "/etc/openclash/core/clash_meta",
                    "elf_class": 64,
                    "elf_machine": 183,
                }
            ),
            encoding="utf-8",
        )
        destination = tmp / "package/files/clash_meta"
        report = tmp / "openclash-core-verification.txt"

        result = subprocess.run(
            [sys.executable, str(STAGER), str(lock), str(archive), str(destination), str(report)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(f"valid pinned Core archive was rejected:\n{result.stdout}")
        if destination.read_bytes() != core:
            raise AssertionError("staged Core bytes differ from the official archive member")
        if os.name != "nt" and not destination.stat().st_mode & 0o111:
            raise AssertionError("staged Core is not executable")
        for marker in ("OPENCLASH_CORE_BUNDLED=PASS", "OPENCLASH_CORE_ARCH=PASS", "OPENCLASH_CORE_EXECUTABLE=PASS"):
            if marker not in report.read_text(encoding="utf-8"):
                raise AssertionError(f"stage report is missing {marker}")

        source_root = tmp / "source"
        rootfs = tmp / "rootfs"
        staged = source_root / "package/xinzhao/openclash-core/files/clash_meta"
        final_core = rootfs / "etc/openclash/core/clash_meta"
        staged.parent.mkdir(parents=True, exist_ok=True)
        final_core.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(destination, staged)
        shutil.copyfile(destination, final_core)
        package_recipe_copy = source_root / "package/xinzhao/openclash-core/Makefile"
        shutil.copyfile(ROOT / "package/xinzhao/openclash-core/Makefile", package_recipe_copy)
        init = source_root / "feeds/luci/applications/luci-app-openclash/root/etc/init.d/openclash"
        init.parent.mkdir(parents=True, exist_ok=True)
        init.write_text(
            'CLASH="/etc/openclash/clash"\n'
            'meta_core_path="/etc/openclash/core/clash_meta"\n'
            'ln -s "$meta_core_path" /etc/openclash/clash\n'
            '[ ! -f "$CLASH" ] || { fallback; } && { /usr/share/openclash/openclash_core.sh "$core_type"; }\n',
            encoding="utf-8",
        )
        uci = rootfs / "etc/config/openclash"
        uci.parent.mkdir(parents=True, exist_ok=True)
        uci.write_text("option small_flash_memory '0'\noption smart_enable '0'\n", encoding="utf-8")
        manifest = tmp / "firmware.manifest"
        manifest.write_text("luci-app-openclash - 0.47.test\nopenclash-core - alpha.test\n", encoding="utf-8")
        archive_marker = source_root / "bin/packages/test/openclash-core_1_test_aarch64.ipk"
        archive_marker.parent.mkdir(parents=True, exist_ok=True)
        archive_marker.write_bytes(b"test package archive marker")

        final = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if final.returncode != 0:
            raise AssertionError(f"valid final rootfs Core was rejected:\n{final.stdout}")
        if "OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED=PASS" not in final.stdout:
            raise AssertionError(f"final verifier did not gate first-start download behavior:\n{final.stdout}")

        corrupted_core = bytearray(core)
        corrupted_core[30] = 1
        final_core.write_bytes(corrupted_core)
        corrupt = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if corrupt.returncode == 0 or "differs from the verified staged" not in corrupt.stdout:
            raise AssertionError(f"changed final rootfs Core was not rejected:\n{corrupt.stdout}")

        lock_data = json.loads(lock.read_text(encoding="utf-8"))
        lock_data["asset_git_blob_sha1"] = "0" * 40
        lock.write_text(json.dumps(lock_data), encoding="utf-8")
        bad = subprocess.run(
            [sys.executable, str(STAGER), str(lock), str(archive), str(destination), str(report)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if bad.returncode == 0 or "git blob" not in bad.stdout.lower():
            raise AssertionError(f"mismatched Core source pin was not rejected:\n{bad.stdout}")

    print("OPENCLASH_CORE_STAGE_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
