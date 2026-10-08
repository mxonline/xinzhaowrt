#!/usr/bin/env python3
"""Exercise stable-baseline evidence acceptance and fail-closed identity checks."""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FROZEN = "b4448e62ab1e767f9a60221b0600c60c355baf56"
EVIDENCE = "production/evidence/prebuild-openclash-adh-live.json"


def git(repo: pathlib.Path, *args: str, text: bool = True):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text).stdout


def write_json(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def evidence_for(repo: pathlib.Path) -> dict:
    contract = json.loads((repo / "production/product-goal-contract.json").read_text(encoding="utf-8"))
    goal = json.loads((repo / "production/product-goal-verification.json").read_text(encoding="utf-8"))
    prior = git(repo, "show", f"{FROZEN}:{EVIDENCE}")
    prior_json = json.loads(prior)
    source_commit = git(repo, "rev-parse", FROZEN).strip()
    snapshot = {
        "schema_version": 1,
        "observed_at": "2026-10-09T00:00:00Z",
        "github": {"run_id": 7, "source_commit": source_commit, "workflow": "Arthur OpenClash ADH Direct Inspect"},
        "device": {
            "address": "192.168.6.1", "lan_mac": "dc:d8:7c:45:91:99", "firmware": "XinZhaoWrt",
            "target": "qualcommax/ipq60xx", "profile": "jdcloud_re-ss-01", "version": "0.1.5",
            "build_id": "36764137044", "model": "JDCloud RE-SS-01",
        },
        "management_http_status": 200,
        "read_only_observations": {
            "openclash_uci": "enable=1\ndefault_dashboard=zashboard\ndns_port=7874\ncn_port=9090\nenable_redirect_dns=0\nredirect_dns=0\n",
            "openclash_process_and_ports": "---PROC---\n1 root /etc/openclash/core/clash_meta\n---LISTEN---\n127.0.0.1:7874\n0.0.0.0:9090\n---CONFIG---\nexternal-controller: 0.0.0.0:9090\nexternal-ui: /usr/share/openclash/ui\nexternal-ui-name: zashboard\nmixed-port: 7890\nredir-port: 7892\ntproxy-port: 7895\n  enhanced-mode: fake-ip\n  listen: 0.0.0.0:7874\n",
            "zashboard_files": "ZASHBOARD_INDEX=YES\n",
            "http": "200 http://127.0.0.1:9090/ui/zashboard/\nCONTROLLER_VERSION_HTTP=401\n",
            "proxy_traffic": "PROXY_HTTP=204\n",
            "dns_and_adh": "server=127.0.0.1#7874\n---ADH_UCI---\nAdGuardHome.AdGuardHome.enabled='0'\n---ADH_PROC---\n\n---ADH_YAML_DNS---\nport: 1745\n",
            "memory_and_logs": "MemAvailable: 120000 kB\n",
        },
    }
    markers = {}
    current = {
        "OPENCLASH_CONTROLLER=PASS", "ZASHBOARD_RUNTIME=PASS", "OPENCLASH_RUNTIME_CONFIG_PARITY=PASS",
        "OPENCLASH_DNS_RUNTIME=PASS", "OPENCLASH_ADH_DNS_CHAIN=PASS", "NO_DNS_LOOP=PASS",
        "REAL_PROXY_TRAFFIC=PASS", "NO_PORT_CONFLICT=PASS", "NO_OOM_OR_MANAGEMENT_PLANE_LOSS=PASS", "FINAL_ADH_DEFAULT_OFF=PASS",
    }
    historical = {
        "OPENCLASH_FULLY_USABLE=PASS", "ADGUARDHOME_FULLY_USABLE=PASS", "OPENCLASH_ADH_COEXISTENCE=PASS",
        "ADGUARDHOME_FILTERING=PASS", "ADGUARDHOME_QUERY_LOG=PASS", "ADH_DISABLE_LEAVES_OPENCLASH_WORKING=PASS",
        "ADH_REENABLE_RESTORES_CHAIN=PASS",
    }
    snapshot_ref = "github-actions:mxonline/xinzhaowrt/runs/7/artifacts/8/arthur-live-snapshot.json"
    historical_ref = f"{EVIDENCE}@{prior_json['validated_source_sha']}#sha256={hashlib.sha256(prior.encode('utf-8')).hexdigest()}"
    for marker in contract["prebuild_live_validation"]["required_markers"]:
        if marker not in current and marker not in historical:
            raise SystemExit(f"test fixture has no evidence basis for {marker}")
        markers[marker] = {
            "status": "PASS",
            "basis": "CURRENT_READ_ONLY_SNAPSHOT_AND_SOURCE_PARITY" if marker in current else "EXACT_STABLE_BASELINE_PLUS_PRIOR_FULL_PREBUILD_BEHAVIORAL_EVIDENCE",
            "evidence_ref": snapshot_ref if marker in current else historical_ref,
        }
    canonical = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return {
        "schema_version": 1,
        "gate": "PREBUILD_OPENCLASH_ADH_LIVE_GATE",
        "status": "PASS",
        "mode": "STABLE_PRODUCT_GOAL_PLUS_READ_ONLY_LIVE_SNAPSHOT",
        "generated_at": "2026-10-09T00:00:00Z",
        "validated_source_sha": FROZEN,
        "source_fix": {"source_commit": FROZEN, "status": "STABLE_BASELINE_INHERITANCE_WITH_READ_ONLY_SNAPSHOT"},
        "stable_baseline": {
            "source_sha": goal["source_sha"], "version": goal["device"]["version"], "stable_tag": goal["stable_tag"],
            "build_run_id": goal["build_run_id"], "artifact_id": goal["actions_artifact_id"],
            "sysupgrade_sha256": goal["sysupgrade_sha256"], "factory_sha256": goal["factory_sha256"],
        },
        "prior_full_prebuild_evidence": {
            "source_sha": prior_json["validated_source_sha"],
            "sha256": hashlib.sha256(prior.encode("utf-8")).hexdigest(),
        },
        "source_parity": {
            "baseline_source_sha": "0eeae67f74db77a6401b0205d74e6518b899a3e4",
            "frozen_source_sha": FROZEN,
            "semantic_protected_payload_unchanged": True,
        },
        "current_live_snapshot": {
            "snapshot": snapshot,
            "sha256": hashlib.sha256(canonical).hexdigest(),
            "artifact": {"run_id": 7, "artifact_id": 8, "digest": "sha256:" + "a" * 64},
        },
        "markers": markers,
        "live_runtime_prebuild": {
            "status": "PASS", "source_content_matches_validated_source_commit": True, "final_live_assert": "PASS",
        },
        "restrictions": {
            "build_forbidden": True, "release_forbidden": True, "sysupgrade_forbidden": True,
            "build_executed": False, "release_executed": False, "sysupgrade_executed": False,
        },
    }


def commit(repo: pathlib.Path, message: str) -> str:
    git(repo, "add", EVIDENCE, "production/operator-intent.json", "scripts/check-openclash-adh-prebuild-live.py")
    git(repo, "commit", "-m", message)
    return git(repo, "rev-parse", "HEAD").strip()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="arthur-prebuild-gate-test-") as temporary:
        repo = pathlib.Path(temporary) / "repo"
        subprocess.run(["git", "clone", "--shared", "--no-checkout", str(ROOT), str(repo)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        git(repo, "checkout", "--detach", FROZEN)
        shutil.copy2(ROOT / "scripts/check-openclash-adh-prebuild-live.py", repo / "scripts/check-openclash-adh-prebuild-live.py")
        git(repo, "config", "user.name", "Arthur Gate Test")
        git(repo, "config", "user.email", "arthur-gate-test@example.invalid")
        evidence = evidence_for(repo)
        shutil.copy2(ROOT / "production/operator-intent.json", repo / "production/operator-intent.json")
        write_json(repo / EVIDENCE, evidence)
        valid_commit = commit(repo, "test: valid stable baseline live evidence")
        gate = repo / "scripts/check-openclash-adh-prebuild-live.py"
        passed = subprocess.run(["python", str(gate), valid_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if passed.returncode or "PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS" not in passed.stdout or "FIRMWARE_BUILD_ALLOWED=YES" not in passed.stdout:
            raise SystemExit(f"valid inherited evidence was rejected:\n{passed.stdout}")

        evidence["current_live_snapshot"]["snapshot"]["device"]["version"] = "0.1.6"
        canonical = json.dumps(evidence["current_live_snapshot"]["snapshot"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        evidence["current_live_snapshot"]["sha256"] = hashlib.sha256(canonical).hexdigest()
        write_json(repo / EVIDENCE, evidence)
        invalid_commit = commit(repo, "test: wrong live stable identity")
        failed = subprocess.run(["python", str(gate), invalid_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if failed.returncode == 0 or "live Arthur is not the exact verified Stable build" not in failed.stdout:
            raise SystemExit(f"wrong live device identity was not rejected:\n{failed.stdout}")
    print("PREBUILD_STABLE_INHERITED_EVIDENCE_TEST=PASS")


if __name__ == "__main__":
    main()
