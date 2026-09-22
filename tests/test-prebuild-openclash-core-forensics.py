#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import struct
import subprocess
import sys
import tarfile
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
FORENSICS = ROOT / "scripts/prebuild-openclash-core-forensics.py"


def fake_aarch64_elf() -> bytes:
    image = bytearray(256)
    image[:4] = b"\x7fELF"
    image[4] = 2
    image[5] = 1
    image[6] = 1
    struct.pack_into("<H", image, 16, 2)
    struct.pack_into("<H", image, 18, 183)
    struct.pack_into("<I", image, 20, 1)
    return bytes(image)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def test_reports_all_checkpoints_and_package_rstrip_divergence() -> None:
    with TemporaryDirectory(prefix="openclash-forensics-") as temp:
        root = Path(temp)
        core = fake_aarch64_elf()
        mutated = bytearray(core)
        mutated[128] = 1

        archive = root / "core.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            member = tarfile.TarInfo("clash")
            member.mode = 0o755
            member.size = len(core)
            import io

            bundle.addfile(member, io.BytesIO(core))

        staged = root / "staged" / "clash_meta"
        pkg_build = root / "pkg-build" / "clash_meta"
        package = root / "openclash-core-0.1.0_alpha-r1.apk"
        synthetic = root / "rootfs" / "etc/openclash/core/clash_meta"
        for path in (staged, pkg_build, synthetic):
            path.parent.mkdir(parents=True, exist_ok=True)
        staged.write_bytes(core)
        pkg_build.write_bytes(core)
        synthetic.write_bytes(bytes(mutated))
        for path in (staged, pkg_build, synthetic):
            path.chmod(0o755)

        with tarfile.open(package, "w:gz") as bundle:
            member = tarfile.TarInfo("etc/openclash/core/clash_meta")
            member.mode = 0o755
            member.size = len(mutated)
            import io

            bundle.addfile(member, io.BytesIO(bytes(mutated)))

        archive_bytes = archive.read_bytes()

        lock = root / "lock.json"
        lock.write_text(
            json.dumps(
                {
                    "binary_name": "clash",
                    "install_path": "/etc/openclash/core/clash_meta",
                    "elf_class": 64,
                    "elf_machine": 183,
                    "source_repository": "https://github.com/vernesong/OpenClash",
                    "source_ref": "d" * 40,
                    "asset_size_bytes": len(archive_bytes),
                    "asset_git_blob_sha1": git_blob_sha1(archive_bytes),
                }
            ),
            encoding="utf-8",
        )
        makefile = root / "Makefile"
        makefile.write_text(
            "define Package/openclash-core/install\n"
            "endef\n",
            encoding="utf-8",
        )
        package_pack_mk = root / "package-pack.mk"
        package_pack_mk.write_text(
            "# package payload transformation\n"
            "$(RSTRIP) $$(IDIR_openclash-core)\n",
            encoding="utf-8",
        )
        rstrip_proof = root / "rstrip-proof"
        rstrip_proof.write_bytes(bytes(mutated))
        fixture_modes = root / "fixture-modes.json"
        fixture_modes.write_text(
            json.dumps({"staged": "755", "pkg_build": "755", "synthetic": "755"}),
            encoding="utf-8",
        )
        report = root / "forensics.txt"

        command = [
                sys.executable,
                str(FORENSICS),
                "--lock",
                str(lock),
                "--archive",
                str(archive),
                "--staged",
                str(staged),
                "--pkg-build",
                str(pkg_build),
                "--package",
                str(package),
                "--package-format",
                "tar-fixture",
                "--allow-unknown-mode",
                "--fixture-mode-proof",
                str(fixture_modes),
                "--synthetic-rootfs",
                str(synthetic.parent.parent.parent.parent),
                "--package-makefile",
                str(makefile),
                "--package-pack-mk",
                str(package_pack_mk),
                "--rstrip-proof",
                str(rstrip_proof),
                "--output",
                str(report),
            ]
        result = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        assert result.returncode == 0, result.stdout
        output = report.read_text(encoding="utf-8")
        assert f"OFFICIAL_LOCKED_CORE_SHA256={sha256(staged)}" in output
        assert f"STAGED_CORE_SHA256={sha256(staged)}" in output
        assert f"PKG_BUILD_CORE_SHA256={sha256(pkg_build)}" in output
        assert f"PACKAGE_PAYLOAD_CORE_SHA256={hashlib.sha256(bytes(mutated)).hexdigest()}" in output
        assert f"SYNTHETIC_ROOTFS_CORE_SHA256={hashlib.sha256(bytes(mutated)).hexdigest()}" in output
        assert "CORE_FIRST_DIVERGENCE_STAGE=PACKAGE_PAYLOAD" in output
        assert "CORE_DIVERGENCE_CAUSE=OPENWRT_PACKAGE_RSTRIP" in output
        assert "OPENCLASH_CORE_LOCK_VALIDATED=PASS" in output
        assert "CORE_RSTRIP_PROOF=PASS" in output
        assert "ELFCLASS64=PASS" in output
        assert "AARCH64_MACHINE_183=PASS" in output
        assert "ELF_TYPE_EXECUTABLE=PASS" in output
        assert "STRIPPED=" in output

        comment_only_pack = root / "comment-only-package-pack.mk"
        comment_only_pack.write_text("# $(RSTRIP) must not count as an active transformer\n", encoding="utf-8")
        comment_report = root / "comment-only.txt"
        comment_command = [
            str(comment_only_pack) if value == str(package_pack_mk) else value
            for value in command
        ]
        comment_command[comment_command.index(str(report))] = str(comment_report)
        comment_result = subprocess.run(
            comment_command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        assert comment_result.returncode != 0, comment_result.stdout
        assert "CORE_DIVERGENCE_CAUSE=UNKNOWN_WRITER" in comment_report.read_text(encoding="utf-8")

        apk_command = ["apk" if value == "tar-fixture" else value for value in command]
        apk_result = subprocess.run(
            apk_command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        assert apk_result.returncode != 0, apk_result.stdout


def test_project_verification_wires_the_forensic_collector() -> None:
    verify_project = (ROOT / "scripts/verify-project.sh").read_text(encoding="utf-8")
    assert "prebuild-openclash-core-forensics.py" in verify_project
    assert "PACKAGE_ONLY" in verify_project
    assert "--package-format" in verify_project
    assert "--rstrip-proof" in verify_project
    assert "--package-pack-mk" in verify_project
    assert '"$PYTHON_BIN" tests/test-final-rootfs-adh-manager.py' in verify_project
    assert '"$PYTHON_BIN" tests/test-openclash-core-bundle.py' in verify_project


if __name__ == "__main__":
    test_reports_all_checkpoints_and_package_rstrip_divergence()
    test_project_verification_wires_the_forensic_collector()
    print("PREBUILD_OPENCLASH_CORE_FORENSICS_TEST=PASS")
