#!/usr/bin/env python3
"""Compare accepted QuickStart template bytes across build layers."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def line_endings(data: bytes) -> str:
    crlf = data.count(b"\r\n")
    bare_cr = data.replace(b"\r\n", b"").count(b"\r")
    lf = data.replace(b"\r\n", b"").count(b"\n")
    if crlf and not bare_cr and not lf:
        return "CRLF"
    if lf and not crlf and not bare_cr:
        return "LF"
    if crlf and not bare_cr and lf == crlf:
        return "CRLF"
    if not data:
        return "NONE"
    return "MIXED" if crlf or lf or bare_cr else "NONE"


def first_difference(left: bytes, right: bytes) -> int | None:
    limit = min(len(left), len(right))
    for i in range(limit):
        if left[i] != right[i]:
            return i
    return None if len(left) == len(right) else limit


def layer(path: Path, expected: str | None = None) -> dict[str, object]:
    if not path.is_file():
        return {"path": str(path), "present": False}
    data = path.read_bytes()
    result: dict[str, object] = {
        "path": str(path),
        "present": True,
        "size": len(data),
        "sha256": sha(data),
        "line_endings": line_endings(data),
    }
    if expected:
        result["matches_accepted"] = result["sha256"] == expected
    return result


def git_blob(root: Path, path: str) -> bytes | None:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"HEAD:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def accepted_bytes(data: bytes, expected: str) -> bytes | None:
    normalized = data.replace(b"\r\n", b"\n")
    for candidate in (data, normalized, normalized.replace(b"\n", b"\r\n")):
        if sha(candidate) == expected:
            return candidate
    return None


def source_candidates(root: Path, overlay: str, source: str) -> list[Path]:
    relative = Path(overlay).relative_to("files")
    source_path = Path(source)
    if "quickstart" in source_path.parts:
        source_relative = Path(*source_path.parts[source_path.parts.index("quickstart") + 1:])
    elif tuple(relative.parts[:5]) == ("usr", "lib", "lua", "luci", "view"):
        source_relative = Path("luasrc/view") / Path(*relative.parts[5:])
    else:
        source_relative = Path(*relative.parts[5:])
    candidates = [
        root / "work" / "immortalwrt" / ".xinzhao-feed" / "luci-app-quickstart" / source_relative,
        root / "work" / "immortalwrt" / ".xinzhao-sources" / "istoreos-luci" / "luci" / "luci-app-quickstart" / source_relative,
        root / "work" / "immortalwrt" / ".xinzhao-sources" / "kenzok8-openwrt-packages" / "luci-app-quickstart" / source_relative,
    ]
    return candidates


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--final-rootfs", required=True)
    parser.add_argument("--live-report")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    final_rootfs = Path(args.final_rootfs).resolve()
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    entries = [e for e in manifest.get("frozen_files", []) if "quickstart" in e.get("overlay", "")]
    if not entries:
        raise SystemExit("FAIL: accepted manifest has no QuickStart entries")

    report: dict[str, object] = {"manifest": str(Path(args.manifest).resolve()), "files": []}
    failures: list[str] = []
    for entry in entries:
        overlay = entry["overlay"]
        remote = entry["remote"]
        expected = entry["sha256"]
        repo_path = root / overlay
        repo_data = repo_path.read_bytes() if repo_path.is_file() else b""
        accepted = accepted_bytes(repo_data, expected)
        blob = git_blob(root, overlay)
        if accepted is None or blob is None or accepted_bytes(blob, expected) is None:
            failures.append(f"repo/HEAD drift for {overlay}")
        final_path = final_rootfs / remote.lstrip("/")
        item: dict[str, object] = {
            "overlay": overlay,
            "remote": remote,
            "accepted_preview_source": layer(root / entry["source"], expected),
            "expected_sha256": expected,
            "layers": {
                "repo_worktree": layer(repo_path, expected),
                "repo_head_blob": {"present": blob is not None, "sha256": sha(blob) if blob is not None else None, "line_endings": line_endings(blob) if blob is not None else None},
                "final_rootfs": layer(final_path, expected),
            },
            "sources": [layer(p, expected) for p in source_candidates(root, overlay, entry["source"])],
        }
        if final_path.is_file() and accepted is not None:
            final_data = final_path.read_bytes()
            item["final_first_difference_from_accepted"] = first_difference(final_data, accepted)
            if final_data != accepted:
                failures.append(f"final-rootfs drift for {remote}")
        elif not final_path.is_file():
            failures.append(f"final-rootfs missing {remote}")
        report["files"].append(item)

    if args.live_report:
        live_path = Path(args.live_report)
        report["live_report"] = str(live_path.resolve())
        if live_path.is_file():
            report["live"] = json.loads(live_path.read_text(encoding="utf-8"))
        else:
            failures.append(f"live report missing: {live_path}")

    report["status"] = "PASS" if not failures else "FAIL"
    report["failures"] = failures
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
