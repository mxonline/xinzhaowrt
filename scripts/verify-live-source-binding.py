#!/usr/bin/env python3
"""Bind fresh Arthur live fixes to their source overlays and final rootfs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class BindingError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BindingError(message)


def resolve_runtime_file(root: Path, runtime_path: str, label: str) -> Path:
    parsed = PurePosixPath(runtime_path)
    require(parsed.is_absolute(), f"{label} must be an absolute runtime path: {runtime_path}")
    require(all(part not in ("", ".", "..") for part in parsed.parts[1:]), f"unsafe {label}: {runtime_path}")
    resolved_root = root.resolve()
    candidate = resolved_root.joinpath(*parsed.parts[1:]).resolve()
    try:
        candidate.relative_to(resolved_root)
    except ValueError as exc:
        raise BindingError(f"{label} escapes its root: {runtime_path}") from exc
    return candidate


def resolve_source_file(root: Path, source_path: str) -> Path:
    parsed = PurePosixPath(source_path)
    require(not parsed.is_absolute(), f"source path must be relative: {source_path}")
    require(bool(parsed.parts) and all(part not in ("", ".", "..") for part in parsed.parts), f"unsafe source path: {source_path}")
    resolved_root = root.resolve()
    candidate = resolved_root.joinpath(*parsed.parts).resolve()
    try:
        candidate.relative_to(resolved_root)
    except ValueError as exc:
        raise BindingError(f"source path escapes project root: {source_path}") from exc
    return candidate


def sha256_file(path: Path, label: str) -> str:
    require(path.is_file(), f"missing {label}: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BindingError(f"cannot read source-binding manifest {path}: {exc}") from exc
    require(isinstance(value, dict), "source-binding manifest root must be an object")
    return value


def validate_bindings(project_root: Path, manifest: dict[str, Any]) -> list[tuple[str, Path, str]]:
    live_files = manifest.get("LIVE_CHANGED_FILES")
    source_files = manifest.get("SOURCE_BOUND_FILES")
    require(isinstance(live_files, list), "LIVE_CHANGED_FILES must be a list")
    require(isinstance(source_files, list), "SOURCE_BOUND_FILES must be a list")
    require(len(live_files) == len(source_files), "LIVE_CHANGED_FILES and SOURCE_BOUND_FILES counts differ")
    require(len(live_files) > 0, "no live fixes are listed")

    live_by_path: dict[str, dict[str, Any]] = {}
    for entry in live_files:
        require(isinstance(entry, dict), "LIVE_CHANGED_FILES contains a non-object entry")
        path = entry.get("path")
        digest = entry.get("SHA256")
        require(isinstance(path, str) and path not in live_by_path, f"invalid or duplicate live path: {path}")
        require(isinstance(digest, str) and SHA256_RE.fullmatch(digest), f"invalid live SHA256 for {path}")
        live_by_path[path] = entry

    source_by_path: dict[str, dict[str, Any]] = {}
    for entry in source_files:
        require(isinstance(entry, dict), "SOURCE_BOUND_FILES contains a non-object entry")
        path = entry.get("path")
        digest = entry.get("SOURCE_EFFECTIVE_SHA256")
        source_path = entry.get("source_path")
        require(isinstance(path, str) and path not in source_by_path, f"invalid or duplicate source-bound path: {path}")
        require(isinstance(source_path, str), f"missing source_path for {path}")
        require(isinstance(digest, str) and SHA256_RE.fullmatch(digest), f"invalid effective SHA256 for {path}")
        source_by_path[path] = entry

    require(set(live_by_path) == set(source_by_path), "LIVE_CHANGED_FILES and SOURCE_BOUND_FILES paths differ")
    results: list[tuple[str, Path, str]] = []
    for runtime_path, live_entry in live_by_path.items():
        source_entry = source_by_path[runtime_path]
        runtime_relative = PurePosixPath(*PurePosixPath(runtime_path).parts[1:])
        expected_source_path = PurePosixPath("files", *runtime_relative.parts).as_posix()
        require(source_entry["source_path"] == expected_source_path, f"source path mismatch for {runtime_path}")
        live_digest = live_entry["SHA256"].lower()
        effective_digest = source_entry["SOURCE_EFFECTIVE_SHA256"].lower()
        require(live_digest == effective_digest, f"live/effective SHA256 differs for {runtime_path}")

        source_file = resolve_source_file(project_root, source_entry["source_path"])
        actual_digest = sha256_file(source_file, f"source-bound file for {runtime_path}")
        require(actual_digest == effective_digest, f"source content SHA256 mismatch for {runtime_path}: {actual_digest}")
        results.append((runtime_path, source_file, live_digest))
    return results


def validate_rootfs(rootfs: Path, results: list[tuple[str, Path, str]]) -> None:
    require(rootfs.is_dir(), f"final rootfs directory is missing: {rootfs}")
    checked = 0
    for runtime_path, _, expected_digest in results:
        rootfs_file = resolve_runtime_file(rootfs, runtime_path, "final rootfs path")
        actual_digest = sha256_file(rootfs_file, f"final rootfs file for {runtime_path}")
        require(actual_digest == expected_digest, f"final rootfs SHA256 mismatch for {runtime_path}: {actual_digest}")
        if runtime_path == "/usr/sbin/quickstart":
            mode = stat.S_IMODE(rootfs_file.stat().st_mode)
            require(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH), "final rootfs QuickStart binary is not executable")
        print(f"FINAL_ROOTFS_FILE=PASS path={runtime_path} sha256={actual_digest}")
        checked += 1
    require(checked == len(results), "SOURCE_BOUND_FILES and FINAL_ROOTFS_FILES counts differ")
    print(f"FINAL_ROOTFS_FILES={checked}")
    print("FINAL_ROOTFS_SOURCE_BINDING=PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--rootfs", type=Path)
    args = parser.parse_args()

    try:
        project_root = args.project_root.resolve()
        manifest = read_manifest(args.manifest)
        results = validate_bindings(project_root, manifest)
        print(f"LIVE_CHANGED_FILES={len(manifest['LIVE_CHANGED_FILES'])}")
        print(f"SOURCE_BOUND_FILES={len(manifest['SOURCE_BOUND_FILES'])}")
        for runtime_path, source_file, digest in results:
            print(f"SOURCE_BOUND_FILE=PASS path={runtime_path} source={source_file} sha256={digest}")
        print("SOURCE_BINDING=PASS")
        if args.rootfs is not None:
            try:
                validate_rootfs(args.rootfs.resolve(), results)
            except BindingError:
                print("FINAL_ROOTFS_SOURCE_BINDING=FAIL", file=sys.stderr)
                raise
        return 0
    except BindingError as exc:
        print(f"SOURCE_BINDING=FAIL -- {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
