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
            "protected_openclash_adh_dns_firewall_network_unchanged": True,
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
    git(repo, "add", "-A")
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

        disabled = evidence_for(repo)
        disabled["mode"] = "STABLE_PRODUCT_GOAL_PLUS_OPERATOR_DISABLED_RUNTIME_SNAPSHOT"
        snap = disabled["current_live_snapshot"]["snapshot"]
        snap["runtime_state"] = "OPERATOR_DISABLED"
        snap["openclash_enable"] = 0
        snap["ssh_identity"] = "PASS"
        obs = snap["read_only_observations"]
        obs["openclash_uci"] = "enable=0\ndefault_dashboard=metacubexd\ndns_port=7874\ncn_port=9090\n"
        obs["openclash_process_and_ports"] = "---PROC---\nCORE_PIDS=\n---LISTEN---\n127.0.0.1:80\n---CONFIG---\n"
        obs["http"] = "000 http://127.0.0.1:9090/ui/zashboard/\nCONTROLLER_VERSION_HTTP=000\n"
        obs["proxy_traffic"] = "PROXY_HTTP=000\n"
        obs["dns_and_adh"] = "---DNSMASQ---\n---ADH_UCI---\nAdGuardHome.AdGuardHome.enabled='0'\n---ADH_PROC---\n\n---ADH_YAML_DNS---\nport: 1745\n"
        current = {"NO_OOM_OR_MANAGEMENT_PLANE_LOSS=PASS", "FINAL_ADH_DEFAULT_OFF=PASS"}
        prior = disabled["prior_full_prebuild_evidence"]
        prior_ref = f"{EVIDENCE}@{prior['source_sha']}#sha256={prior['sha256']}"
        for name, marker in disabled["markers"].items():
            if name not in current:
                marker["basis"] = "EXACT_STABLE_BASELINE_PLUS_PRIOR_FULL_PREBUILD_BEHAVIORAL_EVIDENCE"
                marker["evidence_ref"] = prior_ref
        disabled["runtime_capability"] = {"currently_running": "NO", "firmware_capability_inherited": "PASS"}
        disabled["current_live_snapshot"]["sha256"] = hashlib.sha256(json.dumps(snap, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        intent = json.loads((repo / "production/operator-intent.json").read_text(encoding="utf-8"))
        intent["OPENCLASH_RUNTIME_DISABLED_BY_OPERATOR"] = True
        write_json(repo / "production/operator-intent.json", intent)
        write_json(repo / EVIDENCE, disabled)
        disabled_commit = commit(repo, "test: operator-disabled read-only evidence")
        disabled_pass = subprocess.run(["python", str(gate), disabled_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if disabled_pass.returncode or "FIRMWARE_CAPABILITY_INHERITED=PASS" not in disabled_pass.stdout or "CURRENTLY_RUNNING=NO" not in disabled_pass.stdout:
            raise SystemExit(f"operator-disabled unchanged firmware capability was rejected:\n{disabled_pass.stdout}")

        intent.pop("OPENCLASH_RUNTIME_DISABLED_BY_OPERATOR")
        write_json(repo / "production/operator-intent.json", intent)
        no_assertion_commit = commit(repo, "test: missing operator assertion")
        no_assertion = subprocess.run(["python", str(gate), no_assertion_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if no_assertion.returncode == 0 or "operator-disabled assertion" not in no_assertion.stdout:
            raise SystemExit(f"missing operator assertion was not rejected:\n{no_assertion.stdout}")

        git(repo, "checkout", "--detach", disabled_commit)
        recipe = repo / "files/usr/libexec/xinzhao-openclash-lowmem-config"
        recipe.write_text(recipe.read_text(encoding="utf-8") + "\n# unverified runtime change\n", encoding="utf-8")
        changed_payload_commit = commit(repo, "test: changed protected OpenClash runtime payload")
        changed_payload = subprocess.run(["python", str(gate), changed_payload_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if changed_payload.returncode == 0 or "post-freeze changes are outside" not in changed_payload.stdout:
            raise SystemExit(f"changed OpenClash payload was not rejected:\n{changed_payload.stdout}")

        git(repo, "checkout", "--detach", disabled_commit)
        bad_digest = json.loads((repo / EVIDENCE).read_text(encoding="utf-8"))
        bad_digest["prior_full_prebuild_evidence"]["sha256"] = "0" * 64
        write_json(repo / EVIDENCE, bad_digest)
        bad_digest_commit = commit(repo, "test: invalid historical evidence digest")
        digest_result = subprocess.run(["python", str(gate), bad_digest_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if digest_result.returncode == 0 or "prior prebuild evidence digest mismatch" not in digest_result.stdout:
            raise SystemExit(f"historical evidence digest mismatch was not rejected:\n{digest_result.stdout}")

        git(repo, "checkout", "--detach", disabled_commit)
        partial = json.loads((repo / EVIDENCE).read_text(encoding="utf-8"))
        partial_snap = partial["current_live_snapshot"]["snapshot"]
        partial_snap["read_only_observations"]["openclash_process_and_ports"] = "---PROC---\nCORE_PIDS=987\n---LISTEN---\n127.0.0.1:9090\n---CONFIG---\n"
        partial["current_live_snapshot"]["sha256"] = hashlib.sha256(json.dumps(partial_snap, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        write_json(repo / EVIDENCE, partial)
        partial_commit = commit(repo, "test: partially running disabled OpenClash")
        partial_result = subprocess.run(["python", str(gate), partial_commit], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if partial_result.returncode == 0 or "operator-disabled OpenClash has a running core" not in partial_result.stdout:
            raise SystemExit(f"partially running disabled OpenClash was not rejected:\n{partial_result.stdout}")

        git(repo, "checkout", "--detach", valid_commit)

        evidence = evidence_for(repo)
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
