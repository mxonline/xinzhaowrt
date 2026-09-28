#!/usr/bin/env python3
"""One-run-only validator for Arthur Build Run 36348777394."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

RUN_ID = 36348777394
ARTIFACT_ID = 10944450704
ARTIFACT_NAME = "XinZhaoWrt-Arthur"
ARTIFACT_ARCHIVE_SHA256 = "28784b993300f055685934473f32f740e889b30e60ad07b3e5a81e9caf358bd8"
WORKFLOW_NAME = "Build XinZhaoWrt Arthur"
BRANCH = "codex/arthur-smart-build-20260928"
SOURCE_HEAD = "b16ed00ffaed0df927fc5fe482a51153ad9e99d9"
CANDIDATE_TAG = "arthur-update-36348777394"
STABLE_TAG = "arthur-production-36348777394"
SYSUPGRADE_NAME = "XinZhaoWrt-Arthur-v0.1.5-20260927-sysupgrade.bin"
SYSUPGRADE_SHA256 = "97c7860df005e3d222d64f91872933c65ce5c77f4063ec641764f1013cf504e4"
FACTORY_NAME = "XinZhaoWrt-Arthur-v0.1.5-20260927-factory.bin"
FACTORY_SHA256 = "9e060c898b3606119e042d6a0abab36b609a618f2ed07d873c350fd24efdc4c0"
SMART_CORE_SHA256 = "36ca7f27eb06c4e6f4b6a7f7b5f3c67c921cd1d7e0a4819c1e16f0d327cf102d"
POSTFLASH_SUMMARY_SHA256 = "c6a75e49e8932d1f09211c0e063acd7ec84947258b2cd7c2b9236a7168c87a4c"
POSTFLASH_CSV_SHA256 = "96c44ddb6028ee4090051ebea84aea079d247a92f1fd0dcd202ac4273d13aea8"
POSTFLASH_EVIDENCE_ARCHIVE_SHA256 = "4bf98af20beaa9cf9e2d631bda3909f66f79274747c645a269d8782679582c99"
SMART_GROUPS = (
    "香港自动",
    "日本自动",
    "狮城自动",
    "美国自动",
    "台湾自动",
    "韩国自动",
    "英国自动",
    "印度自动",
    "自动选择",
)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_run_artifact_identity(run: dict, artifact_index: dict) -> None:
    """Reject every Actions run/artifact other than the authorized pair."""
    _require(run.get("databaseId") == RUN_ID, "Build run ID mismatch")
    _require(run.get("headSha") == SOURCE_HEAD, "Build run headSha mismatch")
    _require(run.get("headBranch") == BRANCH, "Build run branch mismatch")
    _require(run.get("workflowName") == WORKFLOW_NAME, "Build run workflow mismatch")
    _require(run.get("status") == "completed", "Build run is not completed")
    _require(run.get("conclusion") == "success", "Build run did not succeed")

    artifacts = artifact_index.get("artifacts")
    _require(isinstance(artifacts, list), "Actions artifact index is malformed")
    matches = [item for item in artifacts if item.get("id") == ARTIFACT_ID]
    _require(len(matches) == 1, "Actions artifact ID is missing or ambiguous")
    artifact = matches[0]
    _require(artifact.get("name") == ARTIFACT_NAME, "Actions artifact name mismatch")
    _require(artifact.get("expired") is False, "Actions artifact is expired")
    _require(
        artifact.get("digest") == f"sha256:{ARTIFACT_ARCHIVE_SHA256}",
        "Actions artifact archive digest mismatch",
    )
    workflow_run = artifact.get("workflow_run")
    if workflow_run is not None:
        _require(workflow_run.get("id") == RUN_ID, "Actions artifact belongs to another run")
        _require(workflow_run.get("head_sha") == SOURCE_HEAD, "Actions artifact source commit mismatch")
        _require(workflow_run.get("head_branch") == BRANCH, "Actions artifact source branch mismatch")


def verify_sha256_bytes(data: bytes, expected: str) -> None:
    actual = hashlib.sha256(data).hexdigest()
    _require(actual == expected.lower(), f"SHA256 mismatch: expected {expected}, got {actual}")


def _verify_file(path: Path, expected: str) -> None:
    _require(path.is_file() and path.stat().st_size > 0, f"Required file missing or empty: {path}")
    verify_sha256_bytes(path.read_bytes(), expected)


def _verify_checksums(firmware_dir: Path) -> None:
    checksum_file = firmware_dir / "SHA256SUMS.local"
    _require(checksum_file.is_file(), "SHA256SUMS.local is missing")
    checked = set()
    for line in checksum_file.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        fields = line.split(maxsplit=1)
        _require(len(fields) == 2, f"Malformed checksum entry: {line}")
        expected, filename = fields
        filename = filename.lstrip("*")
        _verify_file(firmware_dir / filename, expected)
        checked.add(filename)
    _require(SYSUPGRADE_NAME in checked, "Sysupgrade is absent from SHA256SUMS.local")
    _require(FACTORY_NAME in checked, "Factory image is absent from SHA256SUMS.local")


def validate_payload(artifact_dir: Path, evidence_dir: Path, goal_record: Path) -> None:
    """Validate downloaded run bytes and previously accepted evidence only."""
    build_info_path = artifact_dir / "build-info.txt"
    _require(build_info_path.is_file(), "build-info.txt is missing")
    build_info = build_info_path.read_text(encoding="utf-8")
    for expected_line in (
        f"Build ID: {RUN_ID}",
        "Device: JDCloud RE-SS-01 (Arthur)",
        "Target: qualcommax/ipq60xx",
        "Profile: jdcloud_re-ss-01",
        "Known-Good lock enabled: 0",
        "Source integrity: official_remote+git_fsck+commit_match",
    ):
        _require(expected_line in build_info, f"Build provenance mismatch: {expected_line}")

    firmware_dir = artifact_dir / "firmware"
    _verify_file(firmware_dir / SYSUPGRADE_NAME, SYSUPGRADE_SHA256)
    _verify_file(firmware_dir / FACTORY_NAME, FACTORY_SHA256)
    _verify_checksums(firmware_dir)

    for filename in ("full.config", "required-plugins.txt", "plugin-verification.txt", "openclash-core-verification.txt"):
        _require((artifact_dir / filename).is_file(), f"Build artifact file missing: {filename}")

    required = [
        line.strip()
        for line in (artifact_dir / "required-plugins.txt").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    _require(len(required) == 22 and len(set(required)) == 22, "Required plugin list is not 22 unique entries")
    plugin_result = (artifact_dir / "plugin-verification.txt").read_text(encoding="utf-8")
    _require("Verified required plugins: 22" in plugin_result, "22-plugin verification count missing")
    _require(
        "PASS: all required LuCI plugins were compiled and are present in the final firmware manifest" in plugin_result,
        "22-plugin firmware manifest PASS marker missing",
    )

    core_result = (artifact_dir / "openclash-core-verification.txt").read_text(encoding="utf-8")
    _require(f"SMART_CORE_SHA256_VALUE={SMART_CORE_SHA256}" in core_result, "Pinned Smart Core SHA256 mismatch")
    _require("SMART_CORE_SHA256=PASS" in core_result, "Smart Core build artifact verification missing")

    _verify_file(evidence_dir / "postflash-stability-summary.txt", POSTFLASH_SUMMARY_SHA256)
    _verify_file(evidence_dir / "postflash-stability.csv", POSTFLASH_CSV_SHA256)
    _require(goal_record.is_file(), "Product-goal verification record missing")
    goal = json.loads(goal_record.read_text(encoding="utf-8"))
    _require(goal.get("status") == "PRODUCT_GOAL_VERIFIED", "Product goal is not verified")
    _require(goal.get("build_run_id") == RUN_ID, "Product-goal record Build Run mismatch")
    _require(goal.get("actions_artifact_id") == ARTIFACT_ID, "Product-goal record Artifact ID mismatch")
    _require(goal.get("source_commit") == SOURCE_HEAD, "Product-goal record project commit mismatch")
    _require(goal.get("candidate_tag") == CANDIDATE_TAG, "Product-goal Candidate tag mismatch")
    _require(goal.get("stable_tag") == STABLE_TAG, "Product-goal Stable tag mismatch")
    _require(goal.get("sysupgrade_sha256") == SYSUPGRADE_SHA256, "Product-goal record firmware SHA256 mismatch")
    _require(goal.get("factory_sha256") == FACTORY_SHA256, "Product-goal factory SHA256 mismatch")
    _require(goal.get("smart_core", {}).get("sha256") == SMART_CORE_SHA256, "Product-goal Smart Core SHA256 mismatch")
    _require(goal.get("smart_policy_config") == "PASS", "Product-goal Smart policy config is not PASS")
    _require(goal.get("smart_policy_loaded") == "PASS", "Product-goal Smart policy loaded state is not PASS")
    _require(goal.get("smart_real_traffic", {}).get("status") == "PASS", "Product-goal real traffic is not PASS")
    stability = goal.get("postflash_stability", {})
    _require(stability.get("status") == "PASS", "Product-goal postflash stability is not PASS")
    _require(stability.get("duration_seconds", 0) >= 600, "Product-goal stability evidence is under 10 minutes")
    _require(tuple(goal.get("smart_groups", [])) == SMART_GROUPS, "Product-goal Smart group list mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-json", type=Path, required=True)
    parser.add_argument("--artifact-index", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--evidence-archive", type=Path, required=True)
    parser.add_argument("--goal-record", type=Path, required=True)
    parser.add_argument("--verify-run-only", action="store_true")
    args = parser.parse_args()

    try:
        run = json.loads(args.run_json.read_text(encoding="utf-8"))
        artifact_index = json.loads(args.artifact_index.read_text(encoding="utf-8"))
        validate_run_artifact_identity(run, artifact_index)
        _verify_file(args.evidence_archive, POSTFLASH_EVIDENCE_ARCHIVE_SHA256)
        if not args.verify_run_only:
            validate_payload(args.artifact_dir, args.evidence_dir, args.goal_record)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 1

    print("RUN_AND_ARTIFACT_IDENTITY=PASS")
    if args.verify_run_only:
        return 0
    print("FIRMWARE_AND_CHECKSUMS=PASS")
    print("PLUGIN_MANIFEST=PASS")
    print("EXISTING_POSTFLASH_EVIDENCE_HASHES=PASS")
    print("PRODUCT_GOAL_RECORD=PASS")
    print("ONE_TIME_ARTIFACT_RECOVERY=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
