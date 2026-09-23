#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
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
SMART_SOURCE_LOCK = ROOT / "config/openclash-smart-core.lock.json"
PREBUILD_GATE = ROOT / "scripts/check-openclash-adh-prebuild-live.py"

BUILD_SOURCE_SHA = "34845c3e015162812ea1ce724a50a97a5db36159"


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


def verify_prebuild_gate_rejects_legacy_reused_live_evidence() -> None:
    result = subprocess.run(
        [sys.executable, str(PREBUILD_GATE), BUILD_SOURCE_SHA],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        raise AssertionError(
            "legacy prebuild evidence reuse must be rejected by the exact-source gate:\n"
            + result.stdout
        )
    for marker in (
        "PREBUILD_CLEAN_STATE_PRODUCT_GATE=FAIL",
        "BUILD_ALLOWED=false",
    ):
        if marker not in result.stdout:
            raise AssertionError(f"prebuild gate output is missing {marker!r}:\n{result.stdout}")


def main() -> int:
    verify_prebuild_gate_rejects_legacy_reused_live_evidence()

    lock_source = json.loads(SOURCE_LOCK.read_text(encoding="utf-8"))
    if lock_source.get("source_repository") != "vernesong/OpenClash":
        raise AssertionError("Core source is not the official OpenClash repository")
    if lock_source.get("source_ref") != "dc71e38205fd2d83cc934592d3da8cf6da3e0b51":
        raise AssertionError("Core source must remain pinned to its reviewed immutable commit")
    if lock_source.get("asset_git_blob_sha1") != "5c90d325491032c316849c0ed39711a16dfdda4c":
        raise AssertionError("official arm64 Meta Core archive pin changed")
    if lock_source.get("core_version") != "alpha-ge183c58":
        raise AssertionError("official Meta Core version pin changed")
    smart_lock_source = json.loads(SMART_SOURCE_LOCK.read_text(encoding="utf-8"))
    if smart_lock_source.get("core_type") != "Smart" or smart_lock_source.get("asset_path") != "master/smart/clash-linux-arm64.tar.gz":
        raise AssertionError("official Smart Core lock is missing or points at the wrong asset")
    if smart_lock_source.get("asset_git_blob_sha1") != "3f2a4c135b739ea823ed29d8a7661d8eb0e5d444":
        raise AssertionError("official arm64 Smart Core archive pin changed")
    arthur_config = (ROOT / "config/arthur.config").read_text(encoding="utf-8")
    if "CONFIG_PACKAGE_openclash-core=y" not in arthur_config:
        raise AssertionError("Arthur config does not install the Core package")
    package_recipe = (ROOT / "package/xinzhao/openclash-core/Makefile").read_text(encoding="utf-8")
    if "/etc/openclash/core/clash_meta" not in package_recipe or "$(INSTALL_BIN)" not in package_recipe:
        raise AssertionError("Core package does not install an executable at OpenClash's runtime path")
    if "RSTRIP:=:" not in package_recipe or "STRIP:=:" not in package_recipe:
        raise AssertionError("Core package must disable stripping locally after forensic RSTRIP proof")
    package_version = re.search(r"^PKG_VERSION:=([^\s]+)$", package_recipe, re.MULTILINE)
    if not package_version or not re.fullmatch(r"0\.1\.0_alpha", package_version.group(1)):
        raise AssertionError("Core APK package version metadata must remain 0.1.0_alpha")
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
        staged_smart = source_root / "package/xinzhao/openclash-core/files/clash_smart"
        staged_smart_sha = source_root / "package/xinzhao/openclash-core/files/clash_smart.sha256"
        final_core = rootfs / "etc/openclash/core/clash_meta"
        final_smart = rootfs / "etc/openclash/core/clash_smart"
        final_smart_sha = rootfs / "etc/openclash/core/clash_smart.sha256"
        staged.parent.mkdir(parents=True, exist_ok=True)
        final_core.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(destination, staged)
        shutil.copy2(destination, staged_smart)
        smart_digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        staged_smart_sha.write_text(smart_digest + "\n", encoding="ascii")
        shutil.copy2(destination, final_core)
        shutil.copy2(destination, final_smart)
        shutil.copy2(staged_smart_sha, final_smart_sha)
        if os.name != "nt" and not final_core.stat().st_mode & 0o111:
            raise AssertionError("synthetic final rootfs Core fixture is not executable")
        package_recipe_copy = source_root / "package/xinzhao/openclash-core/Makefile"
        shutil.copyfile(ROOT / "package/xinzhao/openclash-core/Makefile", package_recipe_copy)
        init = source_root / "feeds/luci/applications/luci-app-openclash/root/etc/init.d/openclash"
        init.parent.mkdir(parents=True, exist_ok=True)
        init.write_text(
            'CLASH="/etc/openclash/clash"\n'
            'meta_core_path="/etc/openclash/core/clash_meta"\n'
            'selected_core_path=$(/bin/sh /usr/libexec/xinzhao-openclash-core-select "$RAW_CONFIG_FILE" "$meta_core_path" "$smart_core_path" "$smart_core_sha_path")\n'
            'if [ "$selected_core_path" = "$smart_core_path" ]; then\n'
            'core_type="Smart"\nmeta_core_path="$smart_core_path"\nfi\n'
            'ln -s "$meta_core_path" /etc/openclash/clash\n'
            'LOG_TIP "SMART_CONFIG_PARSE=PASS"\nLOG_TIP "OPENCLASH_SMART_START=PASS"\n'
            'if [ "$core_type" = "Smart" ]; then\n'
            'LOG_TIP "SMART_CORE_SELECTED=PASS"\nelse\n'
            'LOG_TIP "$core_type Core is not Detected installed, Ready to Download..."\n'
            '[ "$core_type" != "Smart" ] && '
            '[ ! -f "$CLASH" ] || { fallback; } && { /usr/share/openclash/openclash_core.sh "$core_type"; }\nfi\n',
            encoding="utf-8",
        )
        selector = source_root / "files/usr/libexec/xinzhao-openclash-core-select"
        selector.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "files/usr/libexec/xinzhao-openclash-core-select", selector)
        rootfs_selector = rootfs / "usr/libexec/xinzhao-openclash-core-select"
        rootfs_selector.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(selector, rootfs_selector)
        updater = source_root / "feeds/luci/applications/luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
        updater.parent.mkdir(parents=True, exist_ok=True)
        updater.write_text('LOG_TIP "Pinned firmware Smart Core is immutable; online Smart Core replacement is disabled"\n', encoding="utf-8")
        uci = rootfs / "etc/config/openclash"
        uci.parent.mkdir(parents=True, exist_ok=True)
        uci.write_text("option small_flash_memory '0'\noption smart_enable '0'\n", encoding="utf-8")
        manifest = tmp / "firmware.manifest"
        manifest.write_text("luci-app-openclash - 0.47.test\nopenclash-core - alpha.test\n", encoding="utf-8")
        archive_marker = source_root / "bin/packages/test/openclash-core-0.1.0_alpha-r1.apk"
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
        if "OPENCLASH_APK_ARCHIVE_PATTERN=PASS" not in final.stdout:
            raise AssertionError(f"final verifier did not recognize the apk-tools archive name:\n{final.stdout}")
        if "OPENCLASH_FIRST_START_NO_CORE_DOWNLOAD_REQUIRED=PASS" not in final.stdout:
            raise AssertionError(f"final verifier did not gate first-start download behavior:\n{final.stdout}")
        rootfs_selector.unlink()
        selector_missing = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if selector_missing.returncode == 0 or "selector" not in selector_missing.stdout.lower():
            raise AssertionError(f"final verifier accepted an image without its Smart Core selector:\n{selector_missing.stdout}")
        shutil.copyfile(selector, rootfs_selector)
        for marker in (
            "OPENCLASH_CORE_BUNDLED=PASS",
            "OPENCLASH_CORE_ARCH=PASS",
            "OPENCLASH_META_CORE_ARCH_VALUE=aarch64/linux-arm64",
            "META_CORE_INCLUDED=PASS",
            "SMART_CORE_INCLUDED=PASS",
            "SMART_CORE_ARCH=PASS",
            "SMART_CORE_ARCH_VALUE=aarch64/linux-arm64",
            "SMART_CORE_SHA256=PASS",
            "SMART_CORE_SELECTOR_INCLUDED=PASS",
            f"META_CORE_SHA256={hashlib.sha256(core).hexdigest()}",
            f"SMART_CORE_SHA256_VALUE={hashlib.sha256(core).hexdigest()}",
            f"SMART_CORE_SELECTOR_SHA256={hashlib.sha256(selector.read_bytes()).hexdigest()}",
        ):
            if marker not in final.stdout.splitlines():
                raise AssertionError(f"final verifier is missing required artifact marker {marker!r}:\n{final.stdout}")
        expected_meta_exec_marker = "OPENCLASH_CORE_EXECUTABLE=PASS" if os.name != "nt" else "OPENCLASH_CORE_EXECUTABLE=UNVERIFIED"
        if expected_meta_exec_marker not in final.stdout.splitlines():
            raise AssertionError(f"final verifier did not report Meta Core executable status from rootfs mode bits:\n{final.stdout}")
        expected_exec_marker = "SMART_CORE_EXECUTABLE=PASS" if os.name != "nt" else "SMART_CORE_EXECUTABLE=UNVERIFIED"
        if expected_exec_marker not in final.stdout.splitlines():
            raise AssertionError(f"final verifier did not report executable status from rootfs mode bits:\n{final.stdout}")
        if os.name != "nt" and rootfs_selector.stat().st_mode & 0o111:
            raise AssertionError("selector fixture must model the mode-0644 shell script invoked through /bin/sh")

        original_smart = final_smart.read_bytes()
        final_smart.write_bytes(original_smart[:-1] + bytes([original_smart[-1] ^ 1]))
        smart_mismatch = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if smart_mismatch.returncode == 0 or "SMART_CORE_INCLUDED=PASS" in smart_mismatch.stdout:
            raise AssertionError(f"changed Smart Core bytes were accepted or emitted an inclusion PASS:\n{smart_mismatch.stdout}")
        final_smart.write_bytes(original_smart)

        original_smart_sha = final_smart_sha.read_text(encoding="ascii")
        final_smart_sha.write_text("0" * 64 + "\n", encoding="ascii")
        bad_smart_sha = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if bad_smart_sha.returncode == 0 or "SMART_CORE_SHA256=PASS" in bad_smart_sha.stdout:
            raise AssertionError(f"mismatched Smart Core SHA sidecar was accepted or emitted a SHA PASS:\n{bad_smart_sha.stdout}")
        final_smart_sha.write_text(original_smart_sha, encoding="ascii")

        wrong_arch = bytearray(original_smart)
        struct.pack_into("<H", wrong_arch, 18, 62)
        wrong_arch = bytes(wrong_arch)
        staged_smart.write_bytes(wrong_arch)
        final_smart.write_bytes(wrong_arch)
        wrong_arch_digest = hashlib.sha256(wrong_arch).hexdigest()
        staged_smart_sha.write_text(wrong_arch_digest + "\n", encoding="ascii")
        final_smart_sha.write_text(wrong_arch_digest + "\n", encoding="ascii")
        bad_arch = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if bad_arch.returncode == 0 or "SMART_CORE_ARCH=PASS" in bad_arch.stdout or "SMART_CORE_ARCH_VALUE=aarch64/linux-arm64" in bad_arch.stdout:
            raise AssertionError(f"non-AArch64 Smart Core was accepted or emitted an AArch64 marker:\n{bad_arch.stdout}")
        staged_smart.write_bytes(original_smart)
        final_smart.write_bytes(original_smart)
        staged_smart_sha.write_text(hashlib.sha256(original_smart).hexdigest() + "\n", encoding="ascii")
        final_smart_sha.write_text(hashlib.sha256(original_smart).hexdigest() + "\n", encoding="ascii")

        original_selector = rootfs_selector.read_bytes()
        rootfs_selector.write_bytes(original_selector + b"# tampered\n")
        selector_mismatch = subprocess.run(
            [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if selector_mismatch.returncode == 0 or "SMART_CORE_SELECTOR_INCLUDED=PASS" in selector_mismatch.stdout:
            raise AssertionError(f"changed rootfs selector was accepted or emitted a selector PASS:\n{selector_mismatch.stdout}")
        rootfs_selector.write_bytes(original_selector)

        if os.name != "nt":
            smart_mode = final_smart.stat().st_mode
            final_smart.chmod(smart_mode & ~0o111)
            not_executable = subprocess.run(
                [sys.executable, str(FINAL_VERIFIER), str(rootfs), str(manifest), str(source_root), "--lock", str(SOURCE_LOCK)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if not_executable.returncode == 0 or "SMART_CORE_EXECUTABLE=PASS" in not_executable.stdout:
                raise AssertionError(f"non-executable Smart Core was accepted or emitted an executable PASS:\n{not_executable.stdout}")
            final_smart.chmod(smart_mode)

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
        if corrupt.returncode == 0 or "differs from the verified staged" not in corrupt.stdout or "META_CORE_INCLUDED=PASS" in corrupt.stdout:
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
