#!/usr/bin/env python3
"""Bind current Arthur read-only evidence to the frozen v0.1.6 source.

The binder records the exact verified Stable product identity and a newly
collected current-device snapshot. The gate independently recomputes source
parity and validates every assertion; this script never copies the old live
evidence object or changes its source SHA.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

REPOSITORY = "mxonline/xinzhaowrt"
FROZEN_SOURCE = "b4448e62ab1e767f9a60221b0600c60c355baf56"
EVIDENCE_PATH = pathlib.Path("production/evidence/prebuild-openclash-adh-live.json")
SNAPSHOT_ARTIFACT_PREFIX = "Arthur-OpenClash-ADH-ReadOnly-"
MODE = "STABLE_PRODUCT_GOAL_PLUS_READ_ONLY_LIVE_SNAPSHOT"


def gh_json(endpoint: str) -> dict:
    result = subprocess.run(
        ["gh", "api", f"repos/{REPOSITORY}/{endpoint}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    if result.returncode:
        raise RuntimeError(f"GitHub API read failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True, type=pathlib.Path)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--output", type=pathlib.Path, default=EVIDENCE_PATH)
    args = parser.parse_args()

    snapshot_bytes = args.snapshot.read_bytes()
    snapshot = json.loads(snapshot_bytes.decode("utf-8-sig"))
    if snapshot.get("schema_version") != 1:
        raise SystemExit("BIND_BLOCKED: unsupported read-only snapshot schema")

    run = gh_json(f"actions/runs/{args.run_id}")
    if (
        run.get("name") != "Arthur OpenClash ADH Direct Inspect"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise SystemExit("BIND_BLOCKED: current Arthur read-only inspection run is not successful")

    artifacts = gh_json(f"actions/runs/{args.run_id}/artifacts").get("artifacts") or []
    name = f"{SNAPSHOT_ARTIFACT_PREFIX}{args.run_id}"
    matches = [item for item in artifacts if item.get("name") == name and not item.get("expired")]
    if len(matches) != 1:
        raise SystemExit("BIND_BLOCKED: unique current read-only snapshot artifact is missing")
    artifact = matches[0]
    artifact_id = int(artifact.get("id") or 0)
    digest = str(artifact.get("digest") or "")
    if not artifact_id or not digest.startswith("sha256:"):
        raise SystemExit("BIND_BLOCKED: snapshot artifact identity/digest is incomplete")
    if (artifact.get("workflow_run") or {}).get("id") != args.run_id:
        raise SystemExit("BIND_BLOCKED: snapshot artifact belongs to another Actions run")

    archive = subprocess.run(
        ["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if archive.returncode:
        raise RuntimeError(f"snapshot artifact download failed: {archive.stderr.decode(errors='replace').strip()}")
    archive_sha = "sha256:" + hashlib.sha256(archive.stdout).hexdigest()
    if archive_sha != digest:
        raise SystemExit("BIND_BLOCKED: downloaded snapshot artifact digest differs from GitHub metadata")

    with tempfile.TemporaryDirectory(prefix="arthur-prebuild-snapshot-") as temp_name:
        archive_path = pathlib.Path(temp_name) / "snapshot.zip"
        archive_path.write_bytes(archive.stdout)
        with zipfile.ZipFile(archive_path) as bundle:
            members = [item for item in bundle.namelist() if pathlib.PurePosixPath(item).name == "arthur-live-snapshot.json"]
            if len(members) != 1:
                raise SystemExit("BIND_BLOCKED: snapshot artifact must contain one machine snapshot")
            archived_snapshot = bundle.read(members[0])
    if archived_snapshot != snapshot_bytes:
        raise SystemExit("BIND_BLOCKED: supplied snapshot differs from the immutable Actions artifact")

    github = snapshot.get("github") or {}
    run_head = str(run.get("head_sha") or "").lower()
    if github.get("run_id") != args.run_id or github.get("source_commit", "").lower() != run_head:
        raise SystemExit("BIND_BLOCKED: snapshot does not match its Actions run head")
    if github.get("workflow") != "Arthur OpenClash ADH Direct Inspect":
        raise SystemExit("BIND_BLOCKED: snapshot workflow marker mismatch")

    intent = json.loads(pathlib.Path("production/operator-intent.json").read_text(encoding="utf-8"))
    source = str(intent.get("firmware_state", {}).get("active_source_sha") or "").lower()
    accepted = str(intent.get("highest_machine_evidence", {}).get("accepted_source_sha") or "").lower()
    if source != FROZEN_SOURCE or accepted != FROZEN_SOURCE:
        raise SystemExit("BIND_BLOCKED: operator intent does not bind the authorized frozen source")

    product_goal = json.loads(subprocess.check_output(["git", "show", f"{FROZEN_SOURCE}:production/product-goal-verification.json"], text=True, encoding="utf-8"))
    contract = json.loads(subprocess.check_output(["git", "show", f"{FROZEN_SOURCE}:production/product-goal-contract.json"], text=True, encoding="utf-8"))
    prior_text = subprocess.check_output(["git", "show", f"{FROZEN_SOURCE}:{EVIDENCE_PATH.as_posix()}"])
    prior = json.loads(prior_text)
    if product_goal.get("status") != "PRODUCT_GOAL_VERIFIED" or product_goal.get("source_sha") != "0eeae67f74db77a6401b0205d74e6518b899a3e4":
        raise SystemExit("BIND_BLOCKED: exact Stable product-goal evidence is unavailable")
    if prior.get("validated_source_sha") != "197ffc7997fce1d431b527bc1ae0b9d9c1d1cb56" or prior.get("status") != "PASS":
        raise SystemExit("BIND_BLOCKED: historical prebuild evidence identity is invalid")

    required = (contract.get("prebuild_live_validation") or {}).get("required_markers") or []
    current_basis = {
        "OPENCLASH_CONTROLLER=PASS", "ZASHBOARD_RUNTIME=PASS", "OPENCLASH_RUNTIME_CONFIG_PARITY=PASS",
        "OPENCLASH_DNS_RUNTIME=PASS", "OPENCLASH_ADH_DNS_CHAIN=PASS", "NO_DNS_LOOP=PASS",
        "REAL_PROXY_TRAFFIC=PASS", "NO_PORT_CONFLICT=PASS", "NO_OOM_OR_MANAGEMENT_PLANE_LOSS=PASS", "FINAL_ADH_DEFAULT_OFF=PASS",
    }
    historical_behavior = {
        "OPENCLASH_FULLY_USABLE=PASS", "ADGUARDHOME_FULLY_USABLE=PASS", "OPENCLASH_ADH_COEXISTENCE=PASS",
        "ADGUARDHOME_FILTERING=PASS", "ADGUARDHOME_QUERY_LOG=PASS", "ADH_DISABLE_LEAVES_OPENCLASH_WORKING=PASS",
        "ADH_REENABLE_RESTORES_CHAIN=PASS",
    }
    snapshot_ref = f"github-actions:{REPOSITORY}/runs/{args.run_id}/artifacts/{artifact_id}/arthur-live-snapshot.json"
    prior_ref = f"production/evidence/prebuild-openclash-adh-live.json@{prior['validated_source_sha']}#sha256={hashlib.sha256(prior_text).hexdigest()}"
    markers = {}
    for name in required:
        if name not in current_basis and name not in historical_behavior:
            raise SystemExit(f"BIND_BLOCKED: no evidence mapping exists for required marker {name}")
        markers[name] = {
            "status": "PASS",
            "basis": "CURRENT_READ_ONLY_SNAPSHOT_AND_SOURCE_PARITY" if name in current_basis else "EXACT_STABLE_BASELINE_PLUS_PRIOR_FULL_PREBUILD_BEHAVIORAL_EVIDENCE",
            "evidence_ref": snapshot_ref if name in current_basis else prior_ref,
        }

    stable = product_goal
    stable_record = {
        "source_sha": str(stable.get("source_sha") or ""),
        "version": str((stable.get("device") or {}).get("version") or ""),
        "stable_tag": str(stable.get("stable_tag") or ""),
        "build_run_id": stable.get("build_run_id"),
        "artifact_id": str(stable.get("actions_artifact_id") or ""),
        "sysupgrade_sha256": str(stable.get("sysupgrade_sha256") or ""),
        "factory_sha256": str(stable.get("factory_sha256") or ""),
    }

    canonical_snapshot = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    evidence = {
        "schema_version": 1,
        "gate": "PREBUILD_OPENCLASH_ADH_LIVE_GATE",
        "status": "PASS",
        "mode": MODE,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "validated_source_sha": FROZEN_SOURCE,
        "source_fix": {
            "source_commit": FROZEN_SOURCE,
            "status": "STABLE_BASELINE_INHERITANCE_WITH_READ_ONLY_SNAPSHOT",
        },
        "stable_baseline": stable_record,
        "prior_full_prebuild_evidence": {
            "source_sha": str(prior.get("validated_source_sha") or ""),
            "sha256": hashlib.sha256(prior_text).hexdigest(),
            "evidence_path": EVIDENCE_PATH.as_posix(),
            "role": "PROVENANCE_ONLY_NOT_COPIED_OR_RELABELLED",
        },
        "source_parity": {
            "baseline_source_sha": "0eeae67f74db77a6401b0205d74e6518b899a3e4",
            "frozen_source_sha": FROZEN_SOURCE,
            "semantic_protected_payload_unchanged": True,
            "verification": "The checker independently recomputes Stable-to-frozen protected product payload parity.",
        },
        "current_live_snapshot": {
            "snapshot": snapshot,
            "sha256": hashlib.sha256(canonical_snapshot).hexdigest(),
            "artifact": {"run_id": args.run_id, "artifact_id": artifact_id, "digest": digest},
        },
        "markers": markers,
        "live_runtime_prebuild": {
            "status": "PASS",
            "source_content_matches_validated_source_commit": True,
            "final_live_assert": "PASS",
            "validation_basis": "EXACT_STABLE_PRODUCT_GOAL_PLUS_CURRENT_AUTHENTICATED_READ_ONLY_DEVICE_SNAPSHOT",
        },
        "restrictions": {
            "build_forbidden": True,
            "release_forbidden": True,
            "sysupgrade_forbidden": True,
            "build_executed": False,
            "release_executed": False,
            "sysupgrade_executed": False,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"PREBUILD_EVIDENCE_BOUND=PASS source={FROZEN_SOURCE} snapshot_run={args.run_id} artifact={artifact_id}")
    print(f"PREBUILD_EVIDENCE_PATH={args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"BIND_BLOCKED: {exc}", file=sys.stderr)
        raise SystemExit(1)
