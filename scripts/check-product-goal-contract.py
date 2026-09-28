#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "production" / "product-goal-contract.json"

def fail(message: str) -> None:
    raise SystemExit(f"PRODUCT_GOAL_CONTRACT_FAIL: {message}")

if not PATH.is_file():
    fail(f"missing {PATH}")

try:
    contract = json.loads(PATH.read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"invalid json: {exc}")

checks = [
    (contract.get("schema_version") == "1.1", "schema_version"),
    (contract.get("authority") == "OPERATOR", "authority"),
    (contract.get("priority_class") == "HIGHEST", "priority_class"),
    (contract.get("contract_id") == "ARTHUR_PRODUCT_GOAL_V1", "contract_id"),
    (contract.get("scope") == "ALL_ARTHUR_LIFECYCLE_STAGES_AND_ALL_AUTOMATION", "scope"),
    (contract.get("goal", {}).get("product_terminal") == "PRODUCT_GOAL_VERIFIED", "product_terminal"),
    (contract.get("goal", {}).get("release_pipeline_terminal") == "PRODUCTION_RELEASED", "release_pipeline_terminal"),
    (contract.get("openclash_adguardhome_coexistence", {}).get("process_presence_is_insufficient") is True, "pid-only-insufficient"),
    (contract.get("openclash_adguardhome_coexistence", {}).get("required_dns_chain") == "LAN:dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874", "dns-chain"),
    (contract.get("execution_rules", {}).get("every_stage_must_load_this_contract") is True, "every-stage"),
    (contract.get("execution_rules", {}).get("build_success_is_not_product_success") is True, "build-not-product-success"),
    (contract.get("execution_rules", {}).get("release_success_is_not_product_success") is True, "release-not-product-success"),
    (contract.get("execution_rules", {}).get("live_validate_before_build_when_safe_and_applicable") is True, "live-before-build"),
    (contract.get("execution_rules", {}).get("do_not_build_known_broken_behavior") is True, "no-known-broken-build"),
    (contract.get("evidence_rules", {}).get("machine_evidence_required") is True, "machine-evidence"),
    (contract.get("prebuild_live_validation", {}).get("required_for_runtime_affecting_changes") is True, "prebuild-live-required"),
    (contract.get("prebuild_live_validation", {}).get("fail_closed_without_valid_evidence") is True, "prebuild-live-fail-closed"),
    (contract.get("prebuild_live_validation", {}).get("source_binding_required") is True, "prebuild-live-source-binding"),
    (contract.get("prebuild_live_validation", {}).get("evidence_path") == "production/evidence/prebuild-openclash-adh-live.json", "prebuild-live-evidence-path"),
    (contract.get("process_contract_version") == "ARTHUR_RELEASE_PROCESS_VNEXT_2026-09-29", "process-contract-version"),
    (contract.get("release_engineering_contract", {}).get("principle") == "REAL_DEVICE_FIRST_SAME_IMPLEMENTATION_SINGLE_BUILD_EXACT_ARTIFACT", "release-engineering-principle"),
    (contract.get("release_engineering_contract", {}).get("live_first", {}).get("build_must_not_be_used_as_a_debugger_when_live_validation_is_safe_and_applicable") is True, "build-not-debugger"),
    (contract.get("release_engineering_contract", {}).get("build_once", {}).get("default_maximum_builds_per_frozen_candidate") == 1, "single-build-default"),
    (contract.get("promotion_policy", {}).get("candidate_and_stable_must_reuse_identical_artifact_bytes") is True, "identical-artifact-promotion"),
    (contract.get("evidence_invalidation_policy", {}).get("repeat_stability_test_only_after_valid_invalidation") is True, "evidence-retest-policy"),
    (contract.get("clean_flash_policy", {}).get("at_most_once_per_exact_candidate_by_default") is True, "single-clean-flash-default"),
    (contract.get("semantic_gate_requirements", {}).get("default_root_password_plaintext_must_cryptographically_match_default_root_password_hash") is True, "root-credential-semantic-gate"),
]
for ok, label in checks:
    if not ok:
        fail(label)

required_caps = {
    "LAN","DHCP","WAN","DNS","SSH","LUCI","WIFI","ISTORE_QUICKSTART",
    "OPENCLASH_FULLY_USABLE","ADGUARDHOME_FULLY_USABLE",
    "OPENCLASH_ADH_COEXISTENCE","REBOOT_PERSISTENCE","SYSTEM_HEALTH"
}
actual_caps = set(contract.get("required_real_device_capabilities", []))
missing = sorted(required_caps - actual_caps)
if missing:
    fail("missing capabilities=" + ",".join(missing))

required_markers = {
    "OPENCLASH_FULLY_USABLE=PASS",
    "ADGUARDHOME_FULLY_USABLE=PASS",
    "OPENCLASH_ADH_COEXISTENCE=PASS",
    "POST_RELEASE_VALIDATED",
    "PRODUCT_GOAL_VERIFIED",
}
actual_markers = set(contract.get("evidence_rules", {}).get("required_final_markers", []))
missing = sorted(required_markers - actual_markers)
if missing:
    fail("missing final markers=" + ",".join(missing))


prebuild_required_markers = {
    "OPENCLASH_FULLY_USABLE=PASS",
    "ADGUARDHOME_FULLY_USABLE=PASS",
    "OPENCLASH_ADH_COEXISTENCE=PASS",
    "OPENCLASH_CONTROLLER=PASS",
    "ZASHBOARD_RUNTIME=PASS",
    "OPENCLASH_RUNTIME_CONFIG_PARITY=PASS",
    "OPENCLASH_DNS_RUNTIME=PASS",
    "OPENCLASH_ADH_DNS_CHAIN=PASS",
    "REAL_PROXY_TRAFFIC=PASS",
    "ADGUARDHOME_FILTERING=PASS",
    "ADGUARDHOME_QUERY_LOG=PASS",
    "NO_DNS_LOOP=PASS",
    "NO_PORT_CONFLICT=PASS",
    "NO_OOM_OR_MANAGEMENT_PLANE_LOSS=PASS",
    "ADH_DISABLE_LEAVES_OPENCLASH_WORKING=PASS",
    "ADH_REENABLE_RESTORES_CHAIN=PASS",
    "FINAL_ADH_DEFAULT_OFF=PASS",
}
actual_prebuild_markers = set(contract.get("prebuild_live_validation", {}).get("required_markers", []))
missing = sorted(prebuild_required_markers - actual_prebuild_markers)
if missing:
    fail("missing prebuild live markers=" + ",".join(missing))

print("ARTHUR_PRODUCT_GOAL_CONTRACT=PASS")
print("ARTHUR_PRODUCT_GOAL_HIGHEST_PRIORITY=PASS")
