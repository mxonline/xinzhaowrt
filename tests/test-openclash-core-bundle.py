#!/usr/bin/env python3
"""Regression tests for official Meta/Smart Core staging and native runtime."""
from __future__ import annotations

import hashlib
import io
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
VERIFIER = ROOT / "scripts/verify-final-rootfs-openclash-core.py"
META_LOCK = ROOT / "config/openclash-core.lock.json"
SMART_LOCK = ROOT / "config/openclash-smart-core.lock.json"


def blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def fake_elf(tag: bytes) -> bytes:
    image = bytearray(64)
    image[:4] = b"\x7fELF"
    image[4:7] = bytes((2, 1, 1))
    struct.pack_into("<H", image, 18, 183)
    image[32 : 32 + len(tag)] = tag
    return bytes(image)


def stage(lock: Path, archive: Path, destination: Path, report: Path) -> None:
    result = subprocess.run(
        [sys.executable, str(STAGER), str(lock), str(archive), str(destination), str(report)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError(f"valid official Core archive was rejected:\n{result.stdout}")


def make_archive(path: Path, data: bytes) -> None:
    with tarfile.open(path, "w:gz") as bundle:
        member = tarfile.TarInfo("clash")
        member.mode = 0o755
        member.size = len(data)
        bundle.addfile(member, io.BytesIO(data))


def main() -> int:
    smart_pin = json.loads(SMART_LOCK.read_text(encoding="utf-8"))
    verified_smart_sha = "36ca7f27eb06c4e6f4b6a7f7b5f3c67c921cd1d7e0a4819c1e16f0d327cf102d"
    if smart_pin.get("core_version") != "alpha-smart-g2e80ed7":
        raise AssertionError("Smart Core lock does not name the Arthur-verified version")
    if smart_pin.get("binary_sha256") != verified_smart_sha:
        raise AssertionError("Smart Core lock does not pin the Arthur-verified executable")
    defaults_source = (ROOT / "files/etc/uci-defaults/95-xinzhao-openclash-defaults").read_text(encoding="utf-8")
    for marker in ("clash_smart.sha256", "clash_smart", "clash_meta", "mv -f"):
        if marker not in defaults_source:
            raise AssertionError(f"first-boot canonical Smart install is missing {marker}")
    arthur_config = (ROOT / "config/arthur.config").read_text(encoding="utf-8")
    if "CONFIG_PACKAGE_openclash-core=y" not in arthur_config:
        raise AssertionError("Arthur config does not install the official Core bundle")
    package_recipe = (ROOT / "package/xinzhao/openclash-core/Makefile").read_text(encoding="utf-8")
    for marker in ("/etc/openclash/core/clash_meta", "/etc/openclash/core/clash_smart", "RSTRIP:=:", "STRIP:=:"):
        if marker not in package_recipe:
            raise AssertionError(f"Core package contract is missing: {marker}")
    build_script = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    if "fetch-openclash-core.sh" not in build_script or "verify-final-rootfs-openclash-core.py" not in build_script:
        raise AssertionError("Core staging and final verification are not wired into the build")

    with tempfile.TemporaryDirectory(prefix="openclash-core-stage-") as tmp_text:
        tmp = Path(tmp_text)
        meta = fake_elf(b"meta")
        smart = fake_elf(b"smart")
        meta_archive = tmp / "meta.tar.gz"
        smart_archive = tmp / "smart.tar.gz"
        make_archive(meta_archive, meta)
        make_archive(smart_archive, smart)

        meta_lock = tmp / "meta-lock.json"
        smart_lock = tmp / "smart-lock.json"
        common = {
            "schema_version": 1,
            "source_repository": "vernesong/OpenClash",
            "source_ref": "a" * 40,
            "binary_name": "clash",
            "elf_class": 64,
            "elf_machine": 183,
        }
        meta_lock.write_text(json.dumps({
            **common,
            "core_version": "alpha-meta-test",
            "core_type": "Meta",
            "asset_path": "master/meta/clash-linux-arm64.tar.gz",
            "asset_size_bytes": meta_archive.stat().st_size,
            "asset_git_blob_sha1": blob_sha(meta_archive.read_bytes()),
            "install_path": "/etc/openclash/core/clash_meta",
        }), encoding="utf-8")
        smart_lock.write_text(json.dumps({
            **common,
            "core_version": "alpha-smart-test",
            "core_type": "Smart",
            "asset_path": "master/smart/clash-linux-arm64.tar.gz",
            "asset_size_bytes": smart_archive.stat().st_size,
            "asset_git_blob_sha1": blob_sha(smart_archive.read_bytes()),
            "binary_sha256": hashlib.sha256(smart).hexdigest(),
            "install_path": "/etc/openclash/core/clash_smart",
        }), encoding="utf-8")

        source = tmp / "source"
        rootfs = tmp / "rootfs"
        staged_meta = source / "package/xinzhao/openclash-core/files/clash_meta"
        staged_smart = source / "package/xinzhao/openclash-core/files/clash_smart"
        stage(meta_lock, meta_archive, staged_meta, tmp / "meta-report.txt")
        stage(smart_lock, smart_archive, staged_smart, tmp / "smart-report.txt")
        wrong_smart_lock = tmp / "wrong-smart-lock.json"
        wrong_smart_pin = json.loads(smart_lock.read_text(encoding="utf-8"))
        wrong_smart_pin["binary_sha256"] = hashlib.sha256(meta).hexdigest()
        wrong_smart_lock.write_text(json.dumps(wrong_smart_pin), encoding="utf-8")
        rejected_destination = tmp / "rejected-clash-smart"
        rejected = subprocess.run(
            [sys.executable, str(STAGER), str(wrong_smart_lock), str(smart_archive), str(rejected_destination), str(tmp / "rejected-report.txt")],
            capture_output=True,
            text=True,
            check=False,
        )
        if rejected.returncode == 0 or rejected_destination.exists():
            raise AssertionError("Smart Core with the wrong executable SHA-256 was staged")
        (staged_smart.with_suffix(".sha256")).write_text(hashlib.sha256(smart).hexdigest() + "\n", encoding="ascii")
        final_meta = rootfs / "etc/openclash/core/clash_meta"
        final_smart = rootfs / "etc/openclash/core/clash_smart"
        final_meta.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staged_meta, final_meta)
        shutil.copy2(staged_smart, final_smart)
        shutil.copy2(staged_smart.with_suffix(".sha256"), final_smart.with_suffix(".sha256"))
        init = source / ".xinzhao-sources/OpenClash/luci-app-openclash/root/etc/init.d/openclash"
        init.parent.mkdir(parents=True, exist_ok=True)
        init.write_text(
            'meta_core_path="/etc/openclash/core/clash_meta"\n'
            'ln -s "$meta_core_path" /etc/openclash/clash\n'
            'change_dnsmasq "$enable_redirect_dns"\n'
            'set_firewall\n'
            '/usr/share/openclash/openclash_core.sh "$core_type"\n',
            encoding="utf-8",
        )
        updater = source / ".xinzhao-sources/OpenClash/luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
        updater.parent.mkdir(parents=True, exist_ok=True)
        updater.write_text('CORE_TYPE="$1"\nCORE_URL_PATH="$RELEASE_BRANCH/smart"\n', encoding="utf-8")
        defaults = rootfs / "etc/uci-defaults/95-xinzhao-openclash-defaults"
        defaults.parent.mkdir(parents=True, exist_ok=True)
        defaults.write_text(
            "smart_core=/etc/openclash/core/clash_smart\n"
            "canonical_core=/etc/openclash/core/clash_meta\n"
            "smart_digest_file=/etc/openclash/core/clash_smart.sha256\n"
            'mv -f "$tmp" "$canonical_core"\n'
            "uci -q set openclash.config.smart_enable='1'\n"
            "uci -q set openclash.config.core_type='Smart'\n"
            "uci -q set openclash.config.auto_smart_switch='1'\n"
            "ua=clash-verge/v2.4.5\n",
            encoding="utf-8",
        )
        uci = rootfs / "etc/config/openclash"
        uci.parent.mkdir(parents=True, exist_ok=True)
        uci.write_text("option small_flash_memory '0'\n", encoding="utf-8")
        manifest = tmp / "firmware.manifest"
        manifest.write_text("luci-app-openclash - 0.47.test\nopenclash-core - alpha.test\n", encoding="utf-8")
        archive_marker = source / "bin/packages/test/openclash-core-0.1.0_alpha-r1.apk"
        archive_marker.parent.mkdir(parents=True, exist_ok=True)
        archive_marker.write_bytes(b"package")

        result = subprocess.run(
            [sys.executable, str(VERIFIER), str(rootfs), str(manifest), str(source), "--lock", str(meta_lock), "--smart-lock", str(smart_lock)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"native final rootfs verification failed:\n{result.stdout}")
        for marker in ("OPENCLASH_NATIVE_RUNTIME=PASS", "OPENCLASH_NATIVE_SMART_DEFAULT=PASS", "SMART_CORE_SHA256=PASS"):
            if marker not in result.stdout:
                raise AssertionError(f"native final verifier is missing {marker}:\n{result.stdout}")

        final_smart.write_bytes(smart + b"tampered")
        rejected = subprocess.run(
            [sys.executable, str(VERIFIER), str(rootfs), str(manifest), str(source), "--lock", str(meta_lock), "--smart-lock", str(smart_lock)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if rejected.returncode == 0:
            raise AssertionError("tampered Smart Core was accepted")

    print("OPENCLASH_CORE_STAGE_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
