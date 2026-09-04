#!/usr/bin/env python3
"""Validate/materialize the frozen Arthur accepted-preview overlay byte-for-byte.

The accepted preview manifest is immutable evidence. Repository text blobs may use
LF while the accepted runtime bytes used CRLF, so the materializer reads the exact
Git blob for the current HEAD and selects only a byte representation whose SHA256
matches the frozen manifest. Checkout line-ending conversion is therefore irrelevant.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(root: Path, path: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"HEAD:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise SystemExit(f"FAIL: cannot read accepted overlay from HEAD: {path}: {detail}")
    return result.stdout


def accepted_payload(data: bytes, expected: str) -> tuple[bytes, str] | None:
    candidates: list[tuple[bytes, str]] = [(data, "raw")]
    lf = data.replace(b"\r\n", b"\n")
    if lf != data:
        candidates.append((lf, "lf"))
    crlf = lf.replace(b"\n", b"\r\n")
    if crlf != data:
        candidates.append((crlf, "crlf"))

    seen: set[bytes] = set()
    for payload, kind in candidates:
        if payload in seen:
            continue
        seen.add(payload)
        if digest(payload) == expected:
            return payload, kind
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument(
        "--manifest",
        default="production/accepted-preview/arthur-adh-quickstart.json",
    )
    parser.add_argument("--dest", help="Image rootfs files directory to materialize into")
    parser.add_argument("--check", action="store_true", help="Validate only")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    manifest_path = root / args.manifest
    if not manifest_path.is_file():
        raise SystemExit(f"FAIL: accepted preview manifest missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("frozen_files") or []
    if not entries:
        raise SystemExit("FAIL: accepted preview manifest has no frozen_files")

    dest_root = Path(args.dest).resolve() if args.dest else None
    if dest_root is not None:
        dest_root.mkdir(parents=True, exist_ok=True)

    representations: dict[str, int] = {}
    for item in entries:
        overlay = item.get("overlay")
        expected = item.get("sha256")
        mode_text = item.get("mode")
        if not overlay or not expected or not mode_text:
            raise SystemExit(f"FAIL: malformed accepted file entry: {item!r}")
        if not overlay.startswith("files/"):
            raise SystemExit(f"FAIL: accepted overlay escapes files/: {overlay}")
        source = root / overlay
        if not source.is_file():
            raise SystemExit(f"FAIL: accepted overlay missing from firmware input: {overlay}")

        data = git_blob(root, overlay)
        match = accepted_payload(data, expected)
        if match is None:
            raise SystemExit(
                f"FAIL: accepted overlay content drift: {overlay} expected={expected} "
                f"git_blob={digest(data)}"
            )
        payload, representation = match
        representations[representation] = representations.get(representation, 0) + 1
        mode = int(mode_text, 8)

        if dest_root is not None:
            relative = Path(overlay).relative_to("files")
            target = dest_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            os.chmod(target, mode)
            if digest(target.read_bytes()) != expected:
                raise SystemExit(f"FAIL: materialized hash mismatch: {overlay}")

    summary = ",".join(f"{k}={v}" for k, v in sorted(representations.items()))
    action = "MATERIALIZED" if dest_root is not None else "CHECKED"
    print(f"ACCEPTED_PREVIEW_{action}=PASS files={len(entries)} representations={summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
