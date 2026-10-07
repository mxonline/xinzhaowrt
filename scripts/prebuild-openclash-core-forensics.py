#!/usr/bin/env python3
"""Trace OpenClash Core bytes through the package-only pipeline.

This collector intentionally fails closed. A real ``.apk`` must be read by
apk-tools; tar archives are accepted only when the caller explicitly selects
the test-only ``tar-fixture`` format.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
from pathlib import Path


SHA1_RE = re.compile(r"^[0-9a-f]{40}$")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def read_archive_member(archive: Path, member_name: str) -> tuple[bytes, int]:
    wanted = member_name.lstrip("./").lstrip("/")
    with tarfile.open(archive, "r:*") as bundle:
        for member in bundle.getmembers():
            normalized = member.name.lstrip("./").lstrip("/")
            if normalized != wanted:
                continue
            handle = bundle.extractfile(member)
            if handle is None:
                break
            return handle.read(), member.mode
    raise ValueError(f"archive member not found: {member_name}")


def read_package_payload(
    package: Path,
    install_path: str,
    package_format: str,
    apk_tool: str | None,
) -> tuple[bytes, int]:
    if package.is_dir():
        payload = package / install_path.lstrip("/")
        return payload.read_bytes(), stat.S_IMODE(payload.stat().st_mode)

    if package_format == "tar-fixture":
        return read_archive_member(package, install_path)
    if package_format != "apk":
        raise ValueError(f"unsupported package format: {package_format}")

    tool = apk_tool or shutil.which("apk")
    if not tool:
        raise RuntimeError("apk-tools is required to inspect a real .apk package")
    with tempfile.TemporaryDirectory(prefix="openclash-apk-") as temp:
        result = subprocess.run(
            [tool, "extract", "--root", temp, str(package)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if result.returncode != 0:
            detail = " ".join(result.stdout.split())
            raise RuntimeError(f"apk extract failed: {detail or result.returncode}")
        payload = Path(temp) / install_path.lstrip("/")
        if not payload.is_file():
            raise ValueError(f"apk payload missing after extraction: {install_path}")
        return payload.read_bytes(), stat.S_IMODE(payload.stat().st_mode)


def elf_metadata(data: bytes, mode: int | None) -> dict[str, str]:
    metadata: dict[str, str] = {}
    valid_header = len(data) >= 20 and data[:4] == b"\x7fELF" and data[5] in (1, 2)
    if not valid_header:
        metadata.update(
            {
                "ELFCLASS64": "FAIL",
                "AARCH64_MACHINE_183": "FAIL",
                "ELF_TYPE_EXECUTABLE": "FAIL",
                "STRIPPED": "unknown",
            }
        )
    else:
        endian = "<" if data[5] == 1 else ">"
        elf_class = data[4]
        elf_type = struct.unpack_from(f"{endian}H", data, 16)[0]
        machine = struct.unpack_from(f"{endian}H", data, 18)[0]
        metadata["ELFCLASS64"] = "PASS" if elf_class == 2 else "FAIL"
        metadata["AARCH64_MACHINE_183"] = "PASS" if machine == 183 else "FAIL"
        metadata["ELF_TYPE_EXECUTABLE"] = "PASS" if elf_type == 2 else "FAIL"

        stripped = "YES"
        if elf_class == 2 and len(data) >= 64:
            section_offset = struct.unpack_from(f"{endian}Q", data, 40)[0]
            section_size = struct.unpack_from(f"{endian}H", data, 58)[0]
            section_count = struct.unpack_from(f"{endian}H", data, 60)[0]
            if section_offset and section_size and section_count:
                for index in range(section_count):
                    start = section_offset + index * section_size
                    if start + 8 > len(data):
                        stripped = "unknown"
                        break
                    section_type = struct.unpack_from(f"{endian}I", data, start + 4)[0]
                    if section_type in (2, 11):
                        stripped = "NO"
                        break
        metadata["STRIPPED"] = stripped

    if mode is None:
        metadata["EXECUTABLE_MODE"] = "UNKNOWN"
    else:
        metadata["EXECUTABLE_MODE"] = "PASS" if mode & 0o111 else "FAIL"
    return metadata


def command_output(command: list[str]) -> str:
    executable = shutil.which(command[0])
    if not executable:
        return "unavailable"
    try:
        result = subprocess.run(
            [executable, *command[1:]],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError:
        return "unavailable"
    value = " ".join(result.stdout.split())
    return value if result.returncode == 0 and value else "unavailable"


def active_rstrip(makefile: Path) -> bool:
    for raw_line in makefile.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line and "$(RSTRIP)" in line:
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--staged", type=Path, required=True)
    parser.add_argument("--pkg-build", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--package-format", choices=("apk", "tar-fixture"), default="apk")
    parser.add_argument("--allow-unknown-mode", action="store_true")
    parser.add_argument("--fixture-mode-proof", type=Path)
    parser.add_argument("--apk-tool")
    parser.add_argument("--synthetic-rootfs", type=Path, required=True)
    parser.add_argument("--package-makefile", type=Path, required=True)
    parser.add_argument("--package-pack-mk", type=Path, required=True)
    parser.add_argument("--rstrip-proof", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.allow_unknown_mode and args.package_format != "tar-fixture":
        parser.error("--allow-unknown-mode is restricted to tar-fixture tests")
    if args.fixture_mode_proof and not args.allow_unknown_mode:
        parser.error("--fixture-mode-proof requires --allow-unknown-mode")

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    install_path = str(lock["install_path"])
    archive_bytes = args.archive.read_bytes()
    official, official_mode = read_archive_member(args.archive, lock["binary_name"])
    staged = args.staged.read_bytes()
    pkg_build = args.pkg_build.read_bytes()
    staged_mode = stat.S_IMODE(args.staged.stat().st_mode)
    pkg_build_mode = stat.S_IMODE(args.pkg_build.stat().st_mode)
    package_payload, package_mode = read_package_payload(
        args.package, install_path, args.package_format, args.apk_tool
    )
    synthetic_path = args.synthetic_rootfs / install_path.lstrip("/")
    synthetic = synthetic_path.read_bytes()
    synthetic_mode = stat.S_IMODE(synthetic_path.stat().st_mode)
    if args.fixture_mode_proof:
        fixture_modes = json.loads(args.fixture_mode_proof.read_text(encoding="utf-8"))
        staged_mode = int(fixture_modes["staged"], 8)
        pkg_build_mode = int(fixture_modes["pkg_build"], 8)
        synthetic_mode = int(fixture_modes["synthetic"], 8)

    lock_errors: list[str] = []
    if not isinstance(lock.get("source_repository"), str) or not lock["source_repository"]:
        lock_errors.append("source_repository missing")
    if not isinstance(lock.get("source_ref"), str) or not SHA1_RE.fullmatch(lock["source_ref"]):
        lock_errors.append("source_ref must be a 40-hex commit")
    if lock.get("asset_size_bytes") != len(archive_bytes):
        lock_errors.append("asset_size_bytes does not match archive")
    if lock.get("asset_git_blob_sha1") != git_blob_sha1(archive_bytes):
        lock_errors.append("asset_git_blob_sha1 does not match archive")

    checkpoints = [
        ("OFFICIAL_LOCKED", official, official_mode),
        ("STAGED", staged, staged_mode),
        ("PKG_BUILD", pkg_build, pkg_build_mode),
        ("PACKAGE_PAYLOAD", package_payload, package_mode),
        ("SYNTHETIC_ROOTFS", synthetic, synthetic_mode),
    ]
    hashes = {f"{name}_CORE_SHA256": sha256_bytes(data) for name, data, _ in checkpoints}

    divergence = "NONE"
    for (_, previous, _), (current_name, current, _) in zip(checkpoints, checkpoints[1:]):
        if previous != current:
            divergence = current_name
            break

    rstrip_proof = "NOT_APPLICABLE"
    if divergence == "PACKAGE_PAYLOAD" and staged == pkg_build and package_payload != pkg_build:
        proof_data = args.rstrip_proof.read_bytes() if args.rstrip_proof and args.rstrip_proof.is_file() else None
        if active_rstrip(args.package_pack_mk) and proof_data == package_payload:
            cause = "OPENWRT_PACKAGE_RSTRIP"
            rstrip_proof = "PASS"
        else:
            cause = "UNKNOWN_WRITER"
            rstrip_proof = "FAIL"
    elif divergence == "NONE":
        cause = "NONE"
    else:
        cause = "UNKNOWN_WRITER"

    checkpoint_metadata: dict[str, dict[str, str]] = {
        name: elf_metadata(data, mode) for name, data, mode in checkpoints
    }
    official_metadata = checkpoint_metadata["OFFICIAL_LOCKED"]
    report_lines = [
        *[f"{key}={value}" for key, value in hashes.items()],
        f"CORE_FIRST_DIVERGENCE_STAGE={divergence}",
        f"CORE_DIVERGENCE_CAUSE={cause}",
        f"CORE_RSTRIP_PROOF={rstrip_proof}",
        f"OPENCLASH_CORE_LOCK_VALIDATED={'PASS' if not lock_errors else 'FAIL'}",
        *[f"LOCK_ERROR={error}" for error in lock_errors],
        f"CORE_SOURCE_REPOSITORY={lock.get('source_repository', 'UNKNOWN')}",
        f"CORE_SOURCE_REF={lock.get('source_ref', 'UNKNOWN')}",
        f"CORE_ASSET_SIZE_BYTES={len(archive_bytes)}",
        f"CORE_ASSET_GIT_BLOB_SHA1={git_blob_sha1(archive_bytes)}",
        f"FILE={command_output(['file', str(args.staged)])}",
        f"READELF_H={command_output(['readelf', '-h', str(args.staged)])}",
        f"READELF_N={command_output(['readelf', '-n', str(args.staged)])}",
        f"SIZE={command_output(['size', str(args.staged)])}",
    ]
    for name, metadata in checkpoint_metadata.items():
        report_lines.extend(f"{name}_{key}={value}" for key, value in metadata.items())
    report_lines.extend(f"{key}={value}" for key, value in official_metadata.items())

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print("\n".join(report_lines))

    required_metadata = ("ELFCLASS64", "AARCH64_MACHINE_183", "ELF_TYPE_EXECUTABLE")
    metadata_ok = all(
        metadata[key] == "PASS"
        for metadata in checkpoint_metadata.values()
        for key in required_metadata
    )
    mode_ok = all(
        metadata["EXECUTABLE_MODE"] == "PASS"
        or (args.allow_unknown_mode and metadata["EXECUTABLE_MODE"] == "UNKNOWN")
        for metadata in checkpoint_metadata.values()
    )
    if lock_errors or not metadata_ok or not mode_ok or cause == "UNKNOWN_WRITER":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
