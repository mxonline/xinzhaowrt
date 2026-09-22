#!/usr/bin/env python3
"""Fail-closed machine gate for exact-source Arthur product evidence."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def fail(errors: list[str]) -> int:
    print("PREBUILD_CLEAN_STATE_PRODUCT_GATE=FAIL")
    print("REAL_DEVICE_FULL_VALIDATION=FAIL")
    print("FINAL_SOURCE_FROZEN=FAIL")
    print("EXACT_SOURCE_BINDING=FAIL")
    print("BUILD_ALLOWED=false")
    for error in errors:
        print(f"- {error}")
    return 1


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise ValueError(f"missing {label}: {path}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot parse {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return value


def current_source_sha() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.STDOUT
    ).strip()


def get_required_list(contract: dict[str, Any], key: str) -> list[str]:
    value = contract.get(key)
    if not isinstance(value, list) or not value or any(
        not isinstance(item, str) or not item for item in value
    ):
        raise ValueError(f"contract.{key} must be a non-empty list of marker names")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("legacy_source_sha", nargs="?", help="deprecated positional source SHA")
    parser.add_argument("--contract", default="production/product-goal-contract.json")
    parser.add_argument(
        "--evidence",
        default=None,
        help="exact live evidence JSON; defaults to PREBUILD_LIVE_EVIDENCE or the contract path",
    )
    parser.add_argument("--source-sha", default=None)
    args = parser.parse_args()

    try:
        contract_path = Path(args.contract)
        contract = load_json(contract_path, "product-goal-contract")
        evidence_name = args.evidence or os.environ.get("PREBUILD_LIVE_EVIDENCE")
        evidence_path = Path(evidence_name) if evidence_name else Path(contract["evidence_path"])
        evidence = load_json(evidence_path, "live evidence")
    except (ValueError, KeyError, TypeError) as exc:
        return fail([str(exc)])

    errors: list[str] = []
    requested_sha = args.source_sha or args.legacy_source_sha
    if requested_sha is None:
        try:
            requested_sha = current_source_sha()
        except (OSError, subprocess.CalledProcessError) as exc:
            return fail([f"cannot resolve build source SHA: {exc}"])
    if not isinstance(requested_sha, str) or not SHA_RE.fullmatch(requested_sha):
        errors.append(f"build source SHA must be a 40-character lowercase Git SHA, got {requested_sha!r}")

    if contract.get("gate") != "PREBUILD_CLEAN_STATE_PRODUCT_GATE":
        errors.append("contract.gate is not PREBUILD_CLEAN_STATE_PRODUCT_GATE")

    try:
        live_markers = get_required_list(contract, "required_live_markers")
        build_markers = get_required_list(contract, "required_build_markers")
    except ValueError as exc:
        return fail([str(exc)])

    for marker in live_markers + build_markers:
        if evidence.get(marker) != "PASS":
            errors.append(f"{marker} must equal PASS")

    binding = contract.get("source_binding")
    if not isinstance(binding, dict):
        return fail(["contract.source_binding is missing or invalid"])

    evidence_sha = evidence.get(binding.get("evidence_field", "final_source_sha"))
    if not isinstance(evidence_sha, str) or not SHA_RE.fullmatch(evidence_sha):
        errors.append("evidence.final_source_sha must be a 40-character lowercase Git SHA")
    elif evidence_sha != requested_sha:
        errors.append(
            f"evidence.final_source_sha {evidence_sha} does not match build source SHA {requested_sha}"
        )

    rerun_field = binding.get("validation_rerun_field", "validation_rerun_after_final_source_commit")
    if evidence.get(rerun_field) is not True:
        errors.append(f"{rerun_field} must be true")

    reuse_field = binding.get("validation_reuse_field", "validation_reused_without_rerun_after_commit")
    if evidence.get(reuse_field) is not binding.get("validation_reuse_must_equal", False):
        errors.append(f"{reuse_field} must be false")

    defects_field = binding.get("known_runtime_defects_field", "known_runtime_defects")
    defects = evidence.get(defects_field)
    if binding.get("known_runtime_defects_must_be_empty", True) and defects not in ([], None):
        errors.append(f"{defects_field} must be an empty list")

    if errors:
        return fail(errors)

    print("PREBUILD_CLEAN_STATE_PRODUCT_GATE=PASS")
    print("REAL_DEVICE_FULL_VALIDATION=PASS")
    print("FINAL_SOURCE_FROZEN=PASS")
    print("EXACT_SOURCE_BINDING=PASS")
    print(f"FINAL_SOURCE_SHA={requested_sha}")
    print("BUILD_ALLOWED=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
