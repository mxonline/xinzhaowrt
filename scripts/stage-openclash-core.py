#!/usr/bin/env python3
"""Verify and stage the pinned official OpenClash Meta Core archive."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import tarfile


class GateError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def git_blob_sha1(data: bytes) -> str:
    header = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(header + data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lock", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    require(lock.get("schema_version") == 1, "unsupported OpenClash Core lock schema")
    require(lock.get("source_repository") == "vernesong/OpenClash", "Core source must be the official OpenClash repository")
    require(re.fullmatch(r"[0-9a-f]{40}", str(lock.get("source_ref", ""))) is not None, "Core source ref must be a full immutable commit")
    require(lock.get("core_type") == "Meta", "Arthur bundle must select the Meta Core")
    require(lock.get("asset_path") == "master/meta/clash-linux-arm64.tar.gz", "unexpected official Core asset path")
    require(lock.get("install_path") == "/etc/openclash/core/clash_meta", "OpenClash Core install path mismatch")
    require(lock.get("binary_name") == "clash", "official archive member name mismatch")
    require(lock.get("elf_class") == 64 and lock.get("elf_machine") == 183, "lock does not identify 64-bit AArch64")

    archive_data = args.archive.read_bytes()
    require(len(archive_data) == int(lock.get("asset_size_bytes", -1)), "official Core asset size mismatch")
    actual_blob = git_blob_sha1(archive_data)
    expected_blob = str(lock.get("asset_git_blob_sha1", ""))
    require(actual_blob == expected_blob, f"Git blob pin mismatch: expected {expected_blob}, got {actual_blob}")

    try:
        with tarfile.open(args.archive, mode="r:gz") as bundle:
            members = bundle.getmembers()
            require(len(members) == 1, "official Core archive must contain exactly one member")
            member = members[0]
            require(member.name == "clash" and member.isfile(), "official Core archive must contain one regular clash file")
            source = bundle.extractfile(member)
            require(source is not None, "official Core archive member cannot be read")
            core = source.read()
    except (tarfile.TarError, OSError) as exc:
        raise GateError(f"official Core archive is invalid: {exc}") from exc

    require(len(core) >= 20 and core[:4] == b"\x7fELF", "OpenClash Core is not an ELF executable")
    require(core[4] == 2, "OpenClash Core ELF class is not 64-bit")
    require(core[5] == 1, "OpenClash Core ELF byte order is not little-endian")
    machine = struct.unpack("<H", core[18:20])[0]
    require(machine == 183, f"OpenClash Core ELF machine is {machine}, expected AArch64 (183)")

    args.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.destination.with_name(args.destination.name + ".verified-tmp")
    temporary.write_bytes(core)
    temporary.chmod(0o755)
    temporary.replace(args.destination)
    digest = hashlib.sha256(core).hexdigest()

    url = (
        "https://raw.githubusercontent.com/"
        + lock["source_repository"]
        + "/"
        + lock["source_ref"]
        + "/"
        + lock["asset_path"]
    )
    lines = [
        f"OPENCLASH_CORE_VERSION={lock['core_version']}",
        f"OPENCLASH_CORE_SOURCE={url}",
        f"OPENCLASH_CORE_SOURCE_REF={lock['source_ref']}",
        f"OPENCLASH_CORE_ASSET_GIT_BLOB_SHA1={actual_blob}",
        f"OPENCLASH_CORE_BINARY_SHA256={digest}",
        f"OPENCLASH_CORE_BINARY_BYTES={len(core)}",
        "OPENCLASH_CORE_BUNDLED=PASS",
        "OPENCLASH_CORE_ARCH=PASS elf_class=64 machine=AArch64",
        "OPENCLASH_CORE_EXECUTABLE=PASS mode=0755",
    ]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("OPENCLASH_CORE_STAGE=PASS " + " ".join(lines[-3:]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"OPENCLASH_CORE_STAGE=FAIL -- {exc}", file=sys.stderr)
        raise SystemExit(1)
