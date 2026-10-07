#!/usr/bin/env python3
"""Fail closed unless the source diff matches its declared exact path set."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def run_git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def fail(reason: str) -> int:
    print("EXPECTED_DIFF_GATE=FAIL")
    print(reason)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    root = args.root.resolve()

    policy_path = root / "production" / "expected-diff.json"
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"EXPECTED_DIFF_POLICY_INVALID={exc}")

    if policy.get("status") != "READY":
        return fail(f"EXPECTED_DIFF_POLICY_NOT_READY={policy.get('status')}")
    if policy.get("baseline") != "production/real-device-baseline.json":
        return fail("EXPECTED_DIFF_BASELINE_MISMATCH")

    base = str(policy.get("comparison_base_source_sha") or "").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return fail("EXPECTED_DIFF_BASE_SHA_INVALID")

    allowed = policy.get("allowed_paths")
    if not isinstance(allowed, list) or not allowed or any(not isinstance(path, str) or not path for path in allowed):
        return fail("EXPECTED_DIFF_ALLOWED_PATHS_INVALID")
    if len(allowed) != len(set(allowed)):
        return fail("EXPECTED_DIFF_ALLOWED_PATHS_DUPLICATED")
    if any(path.startswith("/") or "\\" in path or ".." in Path(path).parts for path in allowed):
        return fail("EXPECTED_DIFF_ALLOWED_PATHS_UNSAFE")
    if "production/expected-diff.json" not in allowed:
        return fail("EXPECTED_DIFF_POLICY_NOT_SELF_BOUND")

    head_result = run_git(root, "rev-parse", "--verify", f"{args.head}^{{commit}}")
    if head_result.returncode != 0:
        return fail(f"EXPECTED_DIFF_HEAD_INVALID={args.head}")
    head = head_result.stdout.strip().lower()

    base_result = run_git(root, "cat-file", "-e", f"{base}^{{commit}}")
    if base_result.returncode != 0:
        return fail(f"EXPECTED_DIFF_BASE_MISSING={base}")
    ancestor = run_git(root, "merge-base", "--is-ancestor", base, head)
    if ancestor.returncode != 0:
        return fail(f"EXPECTED_DIFF_BASE_NOT_ANCESTOR base={base} head={head}")

    changed_result = run_git(root, "diff", "--name-only", "-z", base, head)
    if changed_result.returncode != 0:
        return fail("EXPECTED_DIFF_GIT_DIFF_FAILED")
    changed = sorted(path for path in changed_result.stdout.split("\0") if path)
    expected = sorted(allowed)
    extra = sorted(set(changed) - set(expected))
    missing = sorted(set(expected) - set(changed))
    if extra or missing:
        if extra:
            print("UNDECLARED_CHANGED_PATHS=" + ",".join(extra))
        if missing:
            print("EXPECTED_PATHS_NOT_CHANGED=" + ",".join(missing))
        print("EXPECTED_DIFF_GATE=FAIL")
        return 1

    print(f"EXPECTED_DIFF_GATE=PASS base={base} head={head} changed={len(changed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
