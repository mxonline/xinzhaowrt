#!/usr/bin/env python3
"""Bind historical preview paths to the exact, real-device-verified Stable bytes.

The old preview manifest is retained as history. Its hashes predate later Stable
product fixes, so it cannot be used to overwrite the v0.1.6 firmware overlay.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    require(result.returncode == 0, f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def blob(root: Path, sha: str, path: str) -> bytes:
    return git(root, "show", f"{sha}:{path}")


def mode(root: Path, sha: str, path: str) -> int:
    line = git(root, "ls-tree", sha, "--", path).decode().strip()
    require(line, f"source overlay is absent: {sha}:{path}")
    return int(line.split()[0], 8) & 0o777


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--baseline-sha", help="Optional asserted Stable SHA; must equal machine-verified contract")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    expected = json.loads((root / "production/file-management-expected-diff.json").read_text(encoding="utf-8"))
    verified = json.loads((root / "production/product-goal-verification.json").read_text(encoding="utf-8"))
    intent = json.loads((root / "production/operator-intent.json").read_text(encoding="utf-8"))
    baseline = expected["baseline_source_sha"]
    source = args.source_sha
    require(re.fullmatch(r"[0-9a-f]{40}", source) is not None, "frozen source identity mismatch: invalid SHA")
    require(args.baseline_sha is None or args.baseline_sha == baseline, "baseline source identity mismatch")
    require(verified.get("status") == "PRODUCT_GOAL_VERIFIED" and verified.get("source_commit") == baseline,
            "baseline source identity mismatch: exact Stable machine verification is absent")
    require(source == intent["firmware_state"]["active_source_sha"] == intent["highest_machine_evidence"]["accepted_source_sha"],
            "frozen source identity mismatch")
    require(expected.get("target_release") == intent.get("target_release") == "v0.1.6", "target release mismatch")
    head = git(root, "rev-parse", "HEAD").decode().strip()
    git(root, "merge-base", "--is-ancestor", baseline, source)
    git(root, "merge-base", "--is-ancestor", source, head)

    manifest_path = "production/accepted-preview/arthur-adh-quickstart.json"
    original_bytes = blob(root, source, manifest_path)
    require(blob(root, head, manifest_path) == original_bytes, "historical preview path list changed after source freeze")
    manifest = json.loads(original_bytes)
    entries = manifest.get("frozen_files") or []
    require(entries, "historical preview has no overlay paths")
    seen: set[str] = set()
    stale = 0
    for item in entries:
        path = item.get("overlay")
        require(isinstance(path, str) and path.startswith("files/") and ".." not in Path(path).parts,
                f"unsafe historical overlay path: {path}")
        require(path not in seen, f"duplicate historical overlay path: {path}")
        seen.add(path)
        stable_bytes = blob(root, baseline, path)
        require(blob(root, source, path) == stable_bytes, f"protected Stable overlay changed in frozen source: {path}")
        require(blob(root, head, path) == stable_bytes, f"protected Stable overlay changed after source freeze: {path}")
        expected_mode = int(item["mode"], 8)
        require(all(mode(root, revision, path) == expected_mode for revision in (baseline, source, head)),
                f"protected Stable overlay mode changed: {path}")
        stable_hash = hashlib.sha256(stable_bytes).hexdigest()
        stale += stable_hash != item["sha256"]
        item["historical_preview_sha256"] = item["sha256"]
        item["sha256"] = stable_hash
    manifest["inherited_from_source_sha"] = baseline
    manifest["inherited_to_source_sha"] = source
    manifest["historical_preview_manifest_sha256"] = hashlib.sha256(original_bytes).hexdigest()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"STABLE_OVERLAY_INHERITANCE=PASS files={len(entries)} historical_hashes_superseded={stale} source={source}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"STABLE_OVERLAY_INHERITANCE=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
