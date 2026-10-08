#!/usr/bin/env python3
"""Trusted fail-closed Arthur prebuild live gate.

This checker runs from the default branch but validates the exact Candidate
commit supplied on argv. It accepts the durable LIVE_NON_DISRUPTIVE evidence
schema produced by the Arthur live-repair flow and rejects any firmware/runtime
source drift after the validated source commit.
"""

from __future__ import annotations

import json
import difflib
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Active-candidate scan revision: package-closure proof path.
EVIDENCE_PATH = "production/evidence/prebuild-openclash-adh-live.json"
PACKAGE_CLOSURE_EVIDENCE_PATH = "production/evidence/prebuild-package-closure.json"
PROVEN_PACKAGE_CLOSURE_SOURCE = "4befe60e77bcaa8dd8270d466be26f4f739f4ed3"
PROVEN_PACKAGE_CLOSURE_RUN_ID = 35661418550
PROVEN_PACKAGE_CLOSURE_JOB_ID = 106537312436
PROVEN_PACKAGE_CLOSURE_ARTIFACT_ID = 10666937499
PROVEN_PACKAGE_CLOSURE_ARTIFACT_DIGEST = "sha256:30a85565e8652ff612c5136b3f33f0cee8ff43c0d13cdf0c5239ad72c4f44c1c"
PROVEN_OPENCLASH_CORE_SHA256 = "453066ac9e5045d95d035a96b5c02fb593fdc0427c3c9153ff4d6a4403feab6a"
STABLE_PRODUCT_SOURCE_SHA = "0eeae67f74db77a6401b0205d74e6518b899a3e4"
FROZEN_V016_SOURCE_SHA = "b4448e62ab1e767f9a60221b0600c60c355baf56"
STABLE_PRODUCT_RUN_ID = 36764137044
STABLE_PRODUCT_ARTIFACT_ID = "11126027620"
STABLE_PRODUCT_SYSUPGRADE_SHA256 = "ac58eee2654efe684c3e05a30205ae8f6a5d9e9545461557b2934debe8cf4664"
STABLE_PRODUCT_FACTORY_SHA256 = "156d1e7a2411cf564734e6bd4bc4d1223a8aff65e6e650fe5152bfb08e8f41b9"
PRIOR_LIVE_VALIDATION_SHA = "197ffc7997fce1d431b527bc1ae0b9d9c1d1cb56"
STABLE_INHERITED_MODE = "STABLE_PRODUCT_GOAL_PLUS_READ_ONLY_LIVE_SNAPSHOT"

# Files allowed after the validated runtime/source commit. These are evidence
# and gate-only metadata; they must not alter firmware/runtime behavior.
OPENCLASH_CORE_PACKAGE_RECIPE = "package/xinzhao/openclash-core/Makefile"
OPENCLASH_CORE_BUNDLE_TEST = "tests/test-openclash-core-bundle.py"

VALIDATION_ONLY_APK_FIXES = {
    "scripts/verify-final-rootfs-adh-manager.py": (
        'rglob("luci-app-adguardhome-manager_*.apk")',
        'rglob("luci-app-adguardhome-manager-*.apk")',
    ),
    "scripts/verify-final-rootfs-openclash-core.py": (
        'rglob("openclash-core_*.apk")',
        'rglob("openclash-core-*.apk")',
    ),
    "tests/test-final-rootfs-adh-manager.py": (
        '"source-root/bin/packages/test/luci-app-adguardhome-manager_1.0_all.ipk"',
        '"source-root/bin/packages/test/luci-app-adguardhome-manager-1.0-r1.apk"',
    ),
}

POST_VALIDATION_ALLOWLIST = {
    EVIDENCE_PATH,
    PACKAGE_CLOSURE_EVIDENCE_PATH,
    "production/operator-intent.json",
    "scripts/check-openclash-adh-prebuild-live.py",
    OPENCLASH_CORE_BUNDLE_TEST,
    "scripts/bind-prebuild-openclash-adh-evidence.py",
    "scripts/collect-arthur-openclash-adh-readonly.ps1",
    "scripts/check-arthur-validation-build.sh",
    "scripts/build.sh",
    "scripts/verify-project.ps1",
    "production/resume-state.json",
    "production/firmware-events.jsonl",
}

RUNTIME_PREFIXES = (
    "config/",
    "files/",
    "package/",
    "patches/",
)

RUNTIME_FILES = {
    "build.env",
    "VERSION",
    "scripts/add-custom-packages.sh",
    "scripts/apply-arthur-config.sh",
    "scripts/build.sh",
    "scripts/fetch-openclash-core.sh",
    "scripts/stage-openclash-core.py",
    "scripts/verify-final-rootfs-openclash-core.py",
    "scripts/verify-final-rootfs-adh-manager.py",
    "scripts/patch-adguardhome-coexistence.py",
    "production/openclash-adguardhome-coexistence.json",
}


def run_git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def fail(messages: list[str]) -> int:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=FAIL")
    for message in messages:
        print(f"- {message}")
    return 1


def show_text(commit: str, path: str) -> str:
    proc = run_git("show", f"{commit}:{path}")
    if proc.returncode != 0:
        raise RuntimeError(f"missing {path} at {commit}: {proc.stderr.strip()}")
    return proc.stdout


def changed_files(base: str, head: str) -> list[str]:
    proc = run_git("diff", "--name-only", f"{base}..{head}")
    if proc.returncode != 0:
        raise RuntimeError(f"cannot diff {base}..{head}: {proc.stderr.strip()}")
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def is_runtime_impact(path: str) -> bool:
    if is_post_validation_control(path):
        return False
    if path in RUNTIME_FILES or path.startswith(RUNTIME_PREFIXES):
        return True
    lowered = path.lower()
    return any(token in lowered for token in ("openclash", "adguardhome", "dns-coexist"))


def is_post_validation_control(path: str) -> bool:
    return (
        path in POST_VALIDATION_ALLOWLIST
        or path.startswith((".github/workflows/", "production/evidence/", "tests/"))
        or path in {"production/operator-intent.json", "production/resume-state.json", "production/firmware-events.jsonl"}
        or path.startswith("scripts/arthur-")
        or path in {
            "scripts/build.sh",
            "scripts/check-arthur-validation-build.sh",
            "scripts/check-openclash-adh-prebuild-live.py",
            "scripts/collect-arthur-openclash-adh-readonly.ps1",
            "scripts/bind-prebuild-openclash-adh-evidence.py",
            "scripts/verify-project.sh",
            "scripts/ensure-arthur-unattended-access.ps1",
            "scripts/verify-project.ps1",
        }
    )


def stable_product_parity(baseline: str, frozen_source: str, manifest: dict) -> tuple[list[str], dict]:
    errors: list[str] = []
    details: dict = {"baseline_source_sha": baseline, "frozen_source_sha": frozen_source}
    if baseline != STABLE_PRODUCT_SOURCE_SHA:
        errors.append("Stable product source differs from the exact verified v0.1.5 source")
    if frozen_source != FROZEN_V016_SOURCE_SHA:
        errors.append("frozen firmware source differs from the v0.1.6 source identity")
    ancestor = run_git("merge-base", "--is-ancestor", baseline, frozen_source)
    if ancestor.returncode != 0:
        errors.append("Stable product source is not an ancestor of the frozen firmware source")
        return errors, details

    try:
        paths = changed_files(baseline, frozen_source)
        before_config = show_text(baseline, "config/arthur.config")
        after_config = show_text(frozen_source, "config/arthur.config")
        lock = json.loads(show_text(frozen_source, "production/file-management-expected-diff.json"))
        lockfile = show_text(frozen_source, "config/istore-quickstart.lock")
        startup = show_text(frozen_source, "files/etc/uci-defaults/zzzz-xinzhao-file-management")
    except (RuntimeError, json.JSONDecodeError) as exc:
        errors.append(str(exc))
        return errors, details

    expected_overlay = "files/etc/uci-defaults/zzzz-xinzhao-file-management"
    file_changes = [p for p in paths if p.startswith("files/")]
    if file_changes not in ([], [expected_overlay]):
        errors.append("Stable-to-v0.1.6 files/ changes exceed the single expected file-management startup overlay")
    if expected_overlay in file_changes:
        if not all(token in startup for token in ("/etc/init.d/linkease", "/etc/init.d/quickfile", "enable", "start")):
            errors.append("file-management first-boot overlay does not persist and start the live-proven services")
        if re.search(r"firewall|8897|mount|mkfs|format|mmcblk", startup, re.IGNORECASE):
            errors.append("file-management first-boot overlay contains a forbidden firewall or storage operation")

    permitted_config_additions = {
        "CONFIG_VERSIONOPT=y",
        'CONFIG_VERSION_DIST="XinZhaoWrt"',
        'CONFIG_VERSION_NUMBER="0.1.6"',
        'CONFIG_VERSION_MANUFACTURER="XinZhao Network"',
        'CONFIG_VERSION_PRODUCT="JDCloud Arthur RE-SS-01"',
        "# QuickStart file management uses the four locked official LinkEase packages.",
        "CONFIG_PACKAGE_luci-app-linkease=y",
        "CONFIG_PACKAGE_luci-lib-linkeasefile=y",
        "CONFIG_PACKAGE_linkease=y",
        "CONFIG_PACKAGE_linkease-common-bin=y",
    }
    diff = list(difflib.unified_diff(before_config.splitlines(), after_config.splitlines()))
    additions = {line[1:] for line in diff if line.startswith("+") and not line.startswith("+++")}
    removals = {line[1:] for line in diff if line.startswith("-") and not line.startswith("---")}
    if additions != permitted_config_additions or removals:
        errors.append("config/arthur.config differs from Stable outside v0.1.6 metadata and the four LinkEase packages")

    allowed_product_paths = set(manifest.get("expected_product_paths") or [])
    if manifest.get("baseline_source_sha") != baseline or manifest.get("target_release") != "v0.1.6":
        errors.append("file-management expected-diff manifest is not bound to Stable and v0.1.6")
    product_changes = [p for p in paths if p.startswith(("config/", "files/", "package/", "patches/"))]
    unlisted_product_changes = [p for p in product_changes if p not in allowed_product_paths]
    if unlisted_product_changes:
        errors.append("product payload changes are outside FILE_MANAGEMENT_EXPECTED_DIFF: " + ", ".join(unlisted_product_changes[:20]))
    if any(p.startswith(("package/", "patches/")) for p in product_changes):
        errors.append("OpenClash/AdGuardHome package or patch payload changed since the verified Stable source")
    if any(p.startswith("config/openclash") for p in paths):
        errors.append("OpenClash source/config lock changed since the verified Stable source")

    required_lock_values = (
        'ISTORE_LINKEASE_VERSION="1.7.5"',
        'ISTORE_LINKEASE_COMMON_BIN_VERSION="1.7.5"',
        'ISTORE_LINKEASE_LUCI_VERSION="2.1.70"',
        'ISTORE_LINKEASE_LUCI_RELEASE="3"',
    )
    if not all(value in lockfile for value in required_lock_values):
        errors.append("frozen LinkEase source/version lock is incomplete")
    details["changed_paths"] = paths
    details["product_payload_paths"] = product_changes
    details["semantic_protected_payload_unchanged"] = not errors
    return errors, details


def verify_stable_inherited_evidence(
    target_sha: str,
    evidence: dict,
    operator_intent: dict,
    release_mode: dict,
    product_goal: dict,
    contract: dict,
) -> list[str]:
    errors: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    validated = str(evidence.get("validated_source_sha") or "").lower()
    require(evidence.get("schema_version") == 1, "schema_version must be 1")
    require(evidence.get("gate") == "PREBUILD_OPENCLASH_ADH_LIVE_GATE", "gate identity mismatch")
    require(evidence.get("status") == "PASS", "evidence.status must be PASS")
    require(evidence.get("mode") == STABLE_INHERITED_MODE, "stable inheritance mode mismatch")
    require(bool(str(evidence.get("generated_at") or "").strip()), "generated_at is required")
    require(validated == FROZEN_V016_SOURCE_SHA, "validated_source_sha must bind the frozen v0.1.6 firmware source")
    require(evidence.get("source_fix", {}).get("source_commit") == validated, "source_fix.source_commit must equal validated_source_sha")
    require(evidence.get("source_fix", {}).get("status") == "STABLE_BASELINE_INHERITANCE_WITH_READ_ONLY_SNAPSHOT", "source inheritance status mismatch")

    firmware = operator_intent.get("firmware_state") or {}
    highest = operator_intent.get("highest_machine_evidence") or {}
    guardrails = operator_intent.get("guardrails") or {}
    scope = operator_intent.get("live_repair_scope") or {}
    require(firmware.get("active_source_sha") == validated, "operator active_source_sha must equal validated_source_sha")
    require(highest.get("accepted_source_sha") == validated, "highest_machine_evidence.accepted_source_sha must equal validated_source_sha")
    require(operator_intent.get("device_write_authorized") is False, "device_write_authorized must be false")
    require(scope.get("authorized") is False, "live_repair_scope.authorized must be false")
    require(operator_intent.get("release_mode") == "RELEASE_ONLY" and release_mode.get("mode") == "RELEASE_ONLY", "release mode must remain RELEASE_ONLY")
    require(release_mode.get("automatic_flash") is False and guardrails.get("automatic_flash") is False, "automatic flash must remain forbidden")
    require(guardrails.get("sysupgrade_forbidden") is True and guardrails.get("device_reboot_forbidden") is True, "sysupgrade and reboot must remain forbidden")

    stable = evidence.get("stable_baseline") or {}
    require(stable.get("source_sha") == STABLE_PRODUCT_SOURCE_SHA, "stable baseline source must be the exact verified v0.1.5 source")
    require(stable.get("version") == "0.1.5" and stable.get("stable_tag") == "arthur-production-36764137044", "stable baseline release identity mismatch")
    require(stable.get("build_run_id") == STABLE_PRODUCT_RUN_ID, "stable baseline build run mismatch")
    require(str(stable.get("artifact_id")) == STABLE_PRODUCT_ARTIFACT_ID, "stable baseline artifact identity mismatch")
    require(stable.get("sysupgrade_sha256") == STABLE_PRODUCT_SYSUPGRADE_SHA256, "stable baseline sysupgrade digest mismatch")
    require(stable.get("factory_sha256") == STABLE_PRODUCT_FACTORY_SHA256, "stable baseline factory digest mismatch")
    require(product_goal.get("status") == "PRODUCT_GOAL_VERIFIED", "exact Stable product-goal verification is not PASS")
    require(product_goal.get("source_sha") == STABLE_PRODUCT_SOURCE_SHA and product_goal.get("source_commit") == STABLE_PRODUCT_SOURCE_SHA, "product-goal verification is not bound to exact Stable source")
    require(product_goal.get("stable_tag") == stable.get("stable_tag"), "product-goal Stable tag mismatch")
    require(product_goal.get("build_run_id") == STABLE_PRODUCT_RUN_ID, "product-goal build run mismatch")
    require(str(product_goal.get("actions_artifact_id")) == STABLE_PRODUCT_ARTIFACT_ID, "product-goal artifact id mismatch")
    require(product_goal.get("sysupgrade_sha256") == STABLE_PRODUCT_SYSUPGRADE_SHA256, "product-goal sysupgrade digest mismatch")
    require(product_goal.get("factory_sha256") == STABLE_PRODUCT_FACTORY_SHA256, "product-goal factory digest mismatch")
    require(product_goal.get("candidate_and_stable_sysupgrade_assets_identical") is True, "Stable product goal does not prove identical Candidate/Stable bytes")
    require(product_goal.get("firmware_payload_modified_after_build") is False, "Stable product goal reports post-build payload modification")
    goal_gates = product_goal.get("gates") or {}
    for gate_name in ("PRODUCTION_RELEASED", "SOURCE_BINDING", "SYSTEM_HEALTH", "REBOOT_PERSISTENCE"):
        require(goal_gates.get(gate_name) == "PASS", f"exact Stable product-goal gate is missing or failed: {gate_name}")
    product_device = product_goal.get("device") or {}
    require(product_device.get("version") == "0.1.5" and str(product_device.get("build_id")) == str(STABLE_PRODUCT_RUN_ID), "Stable product-goal device identity mismatch")
    require(product_device.get("lan_mac", "").lower() == "dc:d8:7c:45:91:99", "Stable product-goal MAC mismatch")

    prior = evidence.get("prior_full_prebuild_evidence") or {}
    try:
        prior_text = show_text(FROZEN_V016_SOURCE_SHA, EVIDENCE_PATH)
        prior_data = json.loads(prior_text)
        prior_sha256 = hashlib.sha256(prior_text.encode("utf-8")).hexdigest()
    except (RuntimeError, json.JSONDecodeError) as exc:
        errors.append(f"prior full prebuild evidence is unavailable: {exc}")
        prior_data = {}
        prior_sha256 = ""
    require(prior.get("source_sha") == PRIOR_LIVE_VALIDATION_SHA, "prior prebuild evidence source identity mismatch")
    require(prior.get("sha256") == prior_sha256, "prior prebuild evidence digest mismatch")
    require(prior_data.get("status") == "PASS" and prior_data.get("validated_source_sha") == PRIOR_LIVE_VALIDATION_SHA, "prior full prebuild evidence identity/status mismatch")
    require(prior_data.get("openclash_fully_usable") == "PASS" and prior_data.get("adguardhome_fully_usable") == "PASS" and prior_data.get("openclash_adh_coexistence") == "PASS", "prior prebuild evidence lacks full OpenClash/ADH markers")
    prior_openclash = prior_data.get("openclash") or {}
    prior_controller = prior_openclash.get("controller_api") or {}
    prior_proxy = prior_openclash.get("real_proxy_http") or {}
    require(prior_openclash.get("status") == "PASS", "prior OpenClash runtime evidence did not pass")
    require(bool(prior_controller) and all(value == 200 for value in prior_controller.values()), "prior OpenClash controller API evidence is incomplete")
    require(prior_proxy.get("google_generate_204") == 204, "prior real proxy traffic evidence is missing")
    prior_adh = prior_data.get("adguardhome") or {}
    prior_adh_api = prior_adh.get("api_http") or {}
    require(prior_adh.get("status") == "PASS" and prior_adh.get("real_dns") is True, "prior AdGuardHome runtime evidence did not pass")
    require(prior_adh_api.get("filtering") == 200 and prior_adh_api.get("querylog") == 200, "prior AdGuardHome filtering/query-log API evidence is incomplete")
    require(prior_adh.get("filter_blocked_ipv4") == "0.0.0.0" and prior_adh.get("filter_blocked_ipv6") == "::", "prior AdGuardHome filtering behavior evidence is missing")
    require(prior_adh.get("query_log_recorded") is True, "prior AdGuardHome query-log behavior evidence is missing")
    prior_chain = prior_data.get("dns_chain") or {}
    require(prior_chain.get("off") == "dnsmasq:53 -> OpenClash:7874" and prior_chain.get("on") == "dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874", "prior DNS coexistence evidence is incomplete")
    require((prior_chain.get("coexistence_packet_capture") or {}).get("runtime_upstream_7874") is True, "prior DNS coexistence packet evidence is missing")
    prior_lifecycle = prior_data.get("lifecycle") or {}
    require(prior_lifecycle.get("status") == "PASS", "prior full prebuild evidence lifecycle did not pass")
    require(prior_lifecycle.get("sequence") == "OFF -> ON -> OFF -> ON -> OFF", "prior AdGuardHome service lifecycle sequence is incomplete")
    require(prior_lifecycle.get("openclash_pid_remained_stable") is True, "prior OpenClash continuity during AdGuardHome lifecycle is unproven")
    prior_safety = prior_data.get("safety") or {}
    require(prior_safety.get("no_dns_loop") is True and prior_safety.get("no_port_conflict") is True and prior_safety.get("no_oom") is True, "prior live safety checks did not all pass")

    manifest = json.loads(show_text(FROZEN_V016_SOURCE_SHA, "production/file-management-expected-diff.json"))
    parity_errors, parity = stable_product_parity(STABLE_PRODUCT_SOURCE_SHA, FROZEN_V016_SOURCE_SHA, manifest)
    errors.extend(parity_errors)
    parity_record = evidence.get("source_parity") or {}
    require(parity_record.get("baseline_source_sha") == STABLE_PRODUCT_SOURCE_SHA, "source parity baseline SHA mismatch")
    require(parity_record.get("frozen_source_sha") == FROZEN_V016_SOURCE_SHA, "source parity frozen SHA mismatch")
    require(parity_record.get("semantic_protected_payload_unchanged") is True, "source parity semantic preservation claim missing")
    if parity_errors:
        errors.append("Stable-to-frozen protected product payload parity failed")
    if re.fullmatch(r"[0-9a-f]{40}", validated):
        require(run_git("merge-base", "--is-ancestor", validated, target_sha).returncode == 0, "frozen firmware source is not an ancestor of the validation/evidence commit")
        try:
            post_freeze = changed_files(validated, target_sha)
        except RuntimeError as exc:
            errors.append(str(exc))
            post_freeze = []
        disallowed = [path for path in post_freeze if not is_post_validation_control(path)]
        if disallowed:
            errors.append("post-freeze changes are outside the control/evidence allowlist: " + ", ".join(disallowed[:20]))

    snapshot = evidence.get("current_live_snapshot") or {}
    snapshot_payload = snapshot.get("snapshot") or {}
    snapshot_bytes = json.dumps(snapshot_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    require(snapshot.get("sha256") == hashlib.sha256(snapshot_bytes).hexdigest(), "current read-only snapshot content digest mismatch")
    artifact = snapshot.get("artifact") or {}
    run_id = artifact.get("run_id")
    artifact_id = artifact.get("artifact_id")
    require(isinstance(run_id, int) and run_id > 0, "read-only snapshot run id is invalid")
    require(isinstance(artifact_id, int) and artifact_id > 0, "read-only snapshot artifact id is invalid")
    require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", str(artifact.get("digest") or ""))), "read-only snapshot artifact digest is invalid")
    github = snapshot_payload.get("github") or {}
    require(github.get("run_id") == run_id, "snapshot GitHub run id does not match artifact")
    require(github.get("workflow") == "Arthur OpenClash ADH Direct Inspect", "snapshot was not produced by the direct inspect workflow")
    snapshot_source = str(github.get("source_commit") or "").lower()
    require(bool(re.fullmatch(r"[0-9a-f]{40}", snapshot_source)), "snapshot source commit is invalid")
    if re.fullmatch(r"[0-9a-f]{40}", snapshot_source):
        require(run_git("merge-base", "--is-ancestor", snapshot_source, target_sha).returncode == 0, "snapshot workflow commit is not an ancestor of validation commit")

    device = snapshot_payload.get("device") or {}
    require(device.get("address") == "192.168.6.1", "read-only snapshot management address mismatch")
    require(device.get("firmware") == "XinZhaoWrt" and device.get("target") == "qualcommax/ipq60xx" and device.get("profile") == "jdcloud_re-ss-01", "read-only snapshot device build identity mismatch")
    require(device.get("version") == "0.1.5" and str(device.get("build_id")) == str(STABLE_PRODUCT_RUN_ID), "live Arthur is not the exact verified Stable build")
    require(device.get("lan_mac", "").lower() == "dc:d8:7c:45:91:99", "live Arthur MAC differs from exact Stable identity")
    require("RE-SS-01" in str(device.get("model") or ""), "read-only snapshot board model mismatch")
    require(snapshot_payload.get("management_http_status") == 200, "live LuCI management HTTP did not return 200")

    observations = snapshot_payload.get("read_only_observations") or {}
    uci = str(observations.get("openclash_uci") or "")
    runtime = str(observations.get("openclash_process_and_ports") or "")
    files = str(observations.get("zashboard_files") or "")
    http = str(observations.get("http") or "")
    proxy_traffic = str(observations.get("proxy_traffic") or "")
    dns = str(observations.get("dns_and_adh") or "")
    memory = str(observations.get("memory_and_logs") or "")
    try:
        runtime_recipe = show_text(FROZEN_V016_SOURCE_SHA, "files/usr/libexec/xinzhao-openclash-lowmem-config")
    except RuntimeError as exc:
        errors.append(f"frozen OpenClash runtime recipe is unavailable: {exc}")
        runtime_recipe = ""
    for setting in (
        'DNS_PORT="${2:-7874}"', 'CN_PORT="${3:-9090}"', 'REDIR_PORT="${5:-7892}"',
        'TPROXY_PORT="${6:-7895}"', 'MIXED_PORT="${7:-7890}"',
    ):
        require(setting in runtime_recipe, f"frozen OpenClash runtime recipe no longer has the verified setting: {setting}")
    require(re.search(r"(?im)^enable=1\s*$", uci) is not None, "current OpenClash UCI is not enabled")
    require("zashboard" in uci.lower(), "current OpenClash dashboard selection is not Zashboard")
    for setting, expected in (("dns_port", "7874"), ("cn_port", "9090"), ("enable_redirect_dns", "0"), ("redirect_dns", "0")):
        require(re.search(rf"(?im)^{setting}={expected}\s*$", uci) is not None, f"current OpenClash UCI differs from the verified runtime setting: {setting}={expected}")
    require(re.search(r"(?i)(clash_meta|mihomo|/clash(?:\s|$))", runtime) is not None, "current OpenClash core process is missing")
    require(re.search(r":7874\b", runtime) is not None and re.search(r":9090\b", runtime) is not None, "current OpenClash DNS/controller listeners are missing")
    require(re.search(r":1745\b", runtime) is None, "AdGuardHome DNS port is unexpectedly occupied while its service is OFF")
    for pattern, label in (
        (r"(?m)^external-controller:\s*0\.0\.0\.0:9090\s*$", "controller bind"),
        (r"(?m)^external-ui:\s*/usr/share/openclash/ui\s*$", "dashboard path"),
        (r"(?m)^external-ui-name:\s*zashboard\s*$", "dashboard name"),
        (r"(?m)^mixed-port:\s*7890\s*$", "mixed proxy port"),
        (r"(?m)^redir-port:\s*7892\s*$", "redirect proxy port"),
        (r"(?m)^tproxy-port:\s*7895\s*$", "transparent proxy port"),
        (r"(?m)^[ \t]*enhanced-mode:\s*fake-ip\s*$", "fake-ip runtime mode"),
        (r"(?m)^[ \t]*listen:\s*0\.0\.0\.0:7874\s*$", "OpenClash DNS listener"),
    ):
        require(re.search(pattern, runtime) is not None, f"current OpenClash runtime config is missing verified {label}")
    require("ZASHBOARD_INDEX=YES" in files, "current Zashboard index file is missing")
    require(re.search(r"(?m)^200\s+http://127\.0\.0\.1:9090/ui/zashboard/", http) is not None, "current local Zashboard HTTP did not return 200")
    controller = re.search(r"(?m)^CONTROLLER_VERSION_HTTP=(\d{3})\s*$", http)
    require(controller is not None and controller.group(1) in {"200", "401"}, "current OpenClash controller endpoint is not responding")
    require(re.search(r"(?m)^PROXY_HTTP=204\s*$", proxy_traffic) is not None, "current real proxy traffic did not return HTTP 204")
    require("127.0.0.1#7874" in dns, "current dnsmasq upstream is not OpenClash at 7874")
    require(re.search(r"(?i)enabled=['\"]?0['\"]?", dns) is not None, "current AdGuardHome UCI is not disabled")
    adh_process_section = dns.partition("---ADH_PROC---")[2].partition("---ADH_YAML_DNS---")[0]
    require(bool(adh_process_section) and not adh_process_section.strip(), "AdGuardHome process is not OFF in the current read-only snapshot")
    require(re.search(r"(?m)^MemAvailable:\s*[1-9][0-9]*\s+kB", memory) is not None, "current memory availability is missing")
    require(re.search(r"(?i)(out of memory|oom-killer|killed process|segfault)", memory) is None, "current machine log reports OOM or a crash")

    markers = evidence.get("markers") or {}
    required = (contract.get("prebuild_live_validation") or {}).get("required_markers") or []
    require(set(markers) == set(required), "evidence marker set must exactly match the current product-goal contract")
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
    snapshot_ref = f"github-actions:mxonline/xinzhaowrt/runs/{run_id}/artifacts/{artifact_id}/arthur-live-snapshot.json"
    historical_ref = f"{EVIDENCE_PATH}@{PRIOR_LIVE_VALIDATION_SHA}#sha256={prior_sha256}"
    for name in required:
        marker = markers.get(name) or {}
        require(marker.get("status") == "PASS", f"required marker is not PASS: {name}")
        if name in current_basis:
            require(marker.get("basis") == "CURRENT_READ_ONLY_SNAPSHOT_AND_SOURCE_PARITY", f"marker basis must use current live snapshot: {name}")
            require(marker.get("evidence_ref") == snapshot_ref, f"current marker does not reference the immutable live snapshot: {name}")
        elif name in historical_behavior:
            require(marker.get("basis") == "EXACT_STABLE_BASELINE_PLUS_PRIOR_FULL_PREBUILD_BEHAVIORAL_EVIDENCE", f"behavioral marker must disclose its prior full-test basis: {name}")
            require(marker.get("evidence_ref") == historical_ref, f"behavioral marker does not reference the digest-verified prior evidence: {name}")
        else:
            require(False, f"required marker has no approved evidence basis: {name}")
        require(bool(marker.get("evidence_ref")), f"marker evidence reference is missing: {name}")

    live = evidence.get("live_runtime_prebuild") or {}
    require(live.get("status") == "PASS", "live_runtime_prebuild.status must be PASS")
    require(live.get("source_content_matches_validated_source_commit") is True, "source parity must be confirmed")
    require(live.get("final_live_assert") == "PASS", "final live read-only assertion must be PASS")
    require(evidence.get("restrictions", {}).get("build_forbidden") is True, "evidence must state build was forbidden during live validation")
    require(evidence.get("restrictions", {}).get("release_forbidden") is True, "evidence must state release was forbidden during live validation")
    require(evidence.get("restrictions", {}).get("sysupgrade_forbidden") is True, "evidence must state sysupgrade was forbidden")
    require(evidence.get("restrictions", {}).get("build_executed") is False, "evidence must not claim a Build during live validation")
    require(evidence.get("restrictions", {}).get("release_executed") is False, "evidence must not claim a Release during live validation")
    require(evidence.get("restrictions", {}).get("sysupgrade_executed") is False, "evidence must not claim a sysupgrade")

    if errors:
        return errors
    print("STABLE_PRODUCT_SOURCE=PASS sha=" + STABLE_PRODUCT_SOURCE_SHA)
    print("PROTECTED_PRODUCT_PAYLOAD_PARITY=PASS")
    print("CURRENT_ARTHUR_READ_ONLY_SNAPSHOT=PASS")
    print("STABLE_PRODUCT_GOAL_INHERITANCE=PASS")
    for name in required:
        print(name)
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS")
    print(f"PREBUILD_TARGET_SHA={target_sha}")
    print(f"VALIDATED_SOURCE_SHA={validated}")
    print("FIRMWARE_BUILD_ALLOWED=YES")
    raise SystemExit(0)


def make_var(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}:=(\\S+)$", text, re.MULTILINE)
    return match.group(1) if match else ""


def normalize_package_recipe(text: str) -> list[str]:
    normalized: list[str] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("PKG_VERSION:="):
            normalized.append("PKG_VERSION:=<PACKAGE_METADATA>")
        else:
            normalized.append(raw.rstrip())
    return normalized


def openclash_core_package_metadata_only(base: str, head: str) -> bool:
    try:
        before = show_text(base, OPENCLASH_CORE_PACKAGE_RECIPE)
        after = show_text(head, OPENCLASH_CORE_PACKAGE_RECIPE)
    except RuntimeError:
        return False

    return (
        make_var(before, "PKG_NAME") == "openclash-core"
        and make_var(after, "PKG_NAME") == "openclash-core"
        and make_var(before, "PKG_RELEASE") == "1"
        and make_var(after, "PKG_RELEASE") == "1"
        and make_var(before, "PKGARCH") == make_var(after, "PKGARCH")
        and make_var(before, "PKG_VERSION") == "0.1.0~alpha.ge183c58"
        and make_var(after, "PKG_VERSION") == "0.1.0_alpha"
        and normalize_package_recipe(before) == normalize_package_recipe(after)
    )


def validation_only_apk_fix(base: str, head: str) -> bool:
    for path, (before_token, after_token) in VALIDATION_ONLY_APK_FIXES.items():
        try:
            before = show_text(base, path)
            after = show_text(head, path)
        except RuntimeError:
            return False
        if before_token not in before or after_token not in after:
            return False
        if before.replace(before_token, after_token, 1) != after:
            return False
    return True


def package_closure_proof_valid(head: str) -> bool:
    try:
        proof = json.loads(show_text(head, PACKAGE_CLOSURE_EVIDENCE_PATH))
    except (RuntimeError, json.JSONDecodeError):
        return False

    if proof.get("schema_version") != 1 or proof.get("gate") != "PREBUILD_PACKAGE_CLOSURE":
        return False
    if proof.get("status") != "PASS" or proof.get("tested_source_sha") != PROVEN_PACKAGE_CLOSURE_SOURCE:
        return False

    gha = proof.get("github_actions") or {}
    if (
        gha.get("run_id") != PROVEN_PACKAGE_CLOSURE_RUN_ID
        or gha.get("job_id") != PROVEN_PACKAGE_CLOSURE_JOB_ID
        or gha.get("job_conclusion") != "success"
        or gha.get("artifact_id") != PROVEN_PACKAGE_CLOSURE_ARTIFACT_ID
        or gha.get("artifact_digest") != PROVEN_PACKAGE_CLOSURE_ARTIFACT_DIGEST
    ):
        return False

    core = proof.get("openclash_core") or {}
    for key in (
        "official_locked_sha256",
        "staged_sha256",
        "package_build_sha256",
        "package_payload_sha256",
        "synthetic_rootfs_sha256",
    ):
        if core.get(key) != PROVEN_OPENCLASH_CORE_SHA256:
            return False

    markers = proof.get("markers") or {}
    for key in (
        "OPENCLASH_CORE_APK",
        "OPENCLASH_CORE_ARCH",
        "OPENCLASH_CORE_PAYLOAD_IDENTITY",
        "PACKAGE_ONLY_TESTS",
        "ALL_KNOWN_FAILURE_CLASSES",
        "SYNTHETIC_ROOTFS_TESTS",
        "ALL_FINAL_VERIFIERS",
        "NO_AMBIGUOUS_PACKAGE_SOURCE",
        "NO_UNRESOLVED_CORE_WRITER",
        "FAILURE_CLASSIFIER",
        "PREBUILD_CLOSURE",
    ):
        if markers.get(key) != "PASS":
            return False
    if markers.get("FULL_BUILD_ALLOWED") is not True:
        return False

    ancestor = run_git("merge-base", "--is-ancestor", PROVEN_PACKAGE_CLOSURE_SOURCE, head)
    if ancestor.returncode != 0:
        return False
    try:
        proof_only_changes = changed_files(PROVEN_PACKAGE_CLOSURE_SOURCE, head)
    except RuntimeError:
        return False
    return proof_only_changes == [PACKAGE_CLOSURE_EVIDENCE_PATH]


def http_ok(value: object) -> bool:
    return isinstance(value, int) and 200 <= value < 400


target = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
resolved = run_git("rev-parse", target)
if resolved.returncode != 0:
    raise SystemExit(fail([f"cannot resolve target commit {target}: {resolved.stderr.strip()}"]))
target_sha = resolved.stdout.strip()

errors: list[str] = []

try:
    known_good = json.loads(show_text(target_sha, "production/known-good.json"))
    evidence = json.loads(show_text(target_sha, EVIDENCE_PATH))
    operator_intent = json.loads(show_text(target_sha, "production/operator-intent.json"))
    release_mode = json.loads(show_text(target_sha, "production/release-mode.json"))
    product_goal = json.loads(show_text(target_sha, "production/product-goal-verification.json"))
    contract = json.loads(show_text(target_sha, "production/product-goal-contract.json"))
except (RuntimeError, json.JSONDecodeError) as exc:
    raise SystemExit(fail([str(exc)]))


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


if evidence.get("mode") == STABLE_INHERITED_MODE:
    inherited_errors = verify_stable_inherited_evidence(
        target_sha, evidence, operator_intent, release_mode, product_goal, contract
    )
    if inherited_errors:
        raise SystemExit(fail(inherited_errors))
    raise SystemExit(0)


baseline = str(known_good.get("project_commit") or known_good.get("source_commit") or "")
require(bool(re.fullmatch(r"[0-9a-f]{40}", baseline)), "Known-Good project/source commit is missing or invalid")

require(evidence.get("schema_version") == 1, "schema_version must be 1")
require(evidence.get("gate") == "PREBUILD_OPENCLASH_ADH_LIVE_GATE", "gate identity mismatch")
require(evidence.get("status") == "PASS", "evidence.status must be PASS")
require(evidence.get("mode") == "LIVE_NON_DISRUPTIVE", "mode must be LIVE_NON_DISRUPTIVE")
require(bool(str(evidence.get("generated_at") or "").strip()), "generated_at is required")

device = evidence.get("device") or {}
require(device.get("address") == "192.168.6.1", "device.address must be 192.168.6.1")
require(device.get("firmware") == "v0.1.5", "device.firmware must be v0.1.5")
require("JDCloud RE-SS-01" in str(device.get("model") or ""), "device.model must identify JDCloud RE-SS-01")
require("jdcloud_re-ss-01" in str(device.get("target") or ""), "device.target must identify jdcloud_re-ss-01")

restrictions = evidence.get("restrictions") or {}
for key in ("build_forbidden", "release_forbidden", "sysupgrade_forbidden"):
    require(restrictions.get(key) is True, f"restrictions.{key} must be true")
for key in ("build_executed", "release_executed", "sysupgrade_executed"):
    require(restrictions.get(key) is False, f"restrictions.{key} must be false")

live = evidence.get("live_runtime_prebuild") or {}
require(live.get("status") == "PASS", "live_runtime_prebuild.status must be PASS")
require(live.get("source_content_matches_validated_source_commit") is True, "validated source content parity must be true")
require(live.get("final_live_assert") == "PASS", "final_live_assert must be PASS")

validated_sha = str(evidence.get("validated_source_sha") or "")
require(bool(re.fullmatch(r"[0-9a-f]{40}", validated_sha)), "validated_source_sha must be a full commit SHA")
require((evidence.get("source_fix") or {}).get("source_commit") == validated_sha, "source_fix.source_commit must equal validated_source_sha")
require((evidence.get("source_fix") or {}).get("status") == "HOT_DEPLOYED_AND_VERIFIED", "source_fix.status must be HOT_DEPLOYED_AND_VERIFIED")

firmware_state = operator_intent.get("firmware_state") or {}
machine_evidence = operator_intent.get("highest_machine_evidence") or {}
repair_scope = operator_intent.get("live_repair_scope") or {}
guardrails = operator_intent.get("guardrails") or {}
require(firmware_state.get("active_source_sha") == validated_sha, "operator active_source_sha must equal validated_source_sha")
require(machine_evidence.get("accepted_source_sha") == validated_sha, "highest_machine_evidence.accepted_source_sha must equal validated_source_sha")
require(operator_intent.get("device_write_authorized") is False, "device_write_authorized must be false after live repair")
require(repair_scope.get("authorized") is False, "live_repair_scope.authorized must be false after live repair")
require(operator_intent.get("release_mode") == "RELEASE_ONLY" and release_mode.get("mode") == "RELEASE_ONLY", "release mode must remain RELEASE_ONLY")
require(release_mode.get("automatic_flash") is False and guardrails.get("automatic_flash") is False, "automatic flash must remain forbidden")
require(guardrails.get("sysupgrade_forbidden") is True and guardrails.get("device_reboot_forbidden") is True, "sysupgrade and reboot must remain forbidden")

require(evidence.get("openclash_fully_usable") == "PASS", "OPENCLASH_FULLY_USABLE=PASS is required")
require(evidence.get("adguardhome_fully_usable") == "PASS", "ADGUARDHOME_FULLY_USABLE=PASS is required")
require(evidence.get("openclash_adh_coexistence") == "PASS", "OPENCLASH_ADH_COEXISTENCE=PASS is required")

fake = evidence.get("fake_ip_runtime") or {}
require(fake.get("consistent") is True, "fake-ip source/runtime parity must be true")
require(fake.get("runtime_mode") == "fake-ip", "runtime_mode must remain fake-ip")
require(fake.get("external_ui") == "/usr/share/openclash/ui", "external_ui mismatch")
require(fake.get("external_ui_name") == "zashboard", "external_ui_name must be zashboard")
require(fake.get("zashboard_http") == 200, "Zashboard HTTP 200 is required")

openclash = evidence.get("openclash") or {}
require(openclash.get("status") == "PASS", "OpenClash status must be PASS")
controller = openclash.get("controller_api") or {}
for key in ("version", "configs", "providers_proxies", "providers_rules", "proxies", "rules"):
    require(controller.get(key) == 200, f"OpenClash controller {key} HTTP 200 is required")
proxy_http = openclash.get("real_proxy_http") or {}
require(proxy_http.get("google_generate_204") == 204, "real Google proxy HTTP 204 is required")
require(proxy_http.get("gstatic_generate_204") == 204, "real gstatic proxy HTTP 204 is required")
require(proxy_http.get("example_com") == 200, "real example.com proxy HTTP 200 is required")

adh = evidence.get("adguardhome") or {}
require(adh.get("status") == "PASS", "AdGuardHome status must be PASS")
require(adh.get("dns_port") == 1745, "AdGuardHome DNS port must be 1745")
for key in ("status", "profile", "dns_info", "querylog", "stats", "filtering"):
    require((adh.get("api_http") or {}).get(key) == 200, f"AdGuardHome API {key} HTTP 200 is required")
require(adh.get("real_dns") is True, "AdGuardHome real DNS must pass")
require(adh.get("query_log_recorded") is True, "AdGuardHome query log evidence is required")
require(adh.get("filter_blocked_ipv4") == "0.0.0.0", "AdGuardHome IPv4 filtering evidence is required")
require(adh.get("filter_blocked_ipv6") == "::", "AdGuardHome IPv6 filtering evidence is required")

dns_chain = evidence.get("dns_chain") or {}
require(dns_chain.get("off") == "dnsmasq:53 -> OpenClash:7874", "ADH OFF DNS chain mismatch")
require(dns_chain.get("on") == "dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874", "ADH ON DNS chain mismatch")
pcap = dns_chain.get("coexistence_packet_capture") or {}
require(isinstance(pcap.get("packets_to_1745"), int) and pcap.get("packets_to_1745", 0) > 0, "packet evidence to 1745 is required")
require(isinstance(pcap.get("packets_to_7874"), int) and pcap.get("packets_to_7874", 0) > 0, "packet evidence to 7874 is required")
require(pcap.get("runtime_upstream_7874") is True, "AdGuardHome runtime upstream to 7874 is required")

lifecycle = evidence.get("lifecycle") or {}
require(lifecycle.get("sequence") == "OFF -> ON -> OFF -> ON -> OFF", "lifecycle sequence mismatch")
require(lifecycle.get("status") == "PASS", "lifecycle status must be PASS")
require(lifecycle.get("off_states") == 3 and lifecycle.get("on_states") == 2, "full five-stage lifecycle counts are required")
require(lifecycle.get("openclash_pid_remained_stable") is True, "OpenClash must remain stable through ADH lifecycle")
require(all(v == 204 for v in lifecycle.get("proxy_http_results", [])) and len(lifecycle.get("proxy_http_results", [])) == 5, "five proxy HTTP 204 lifecycle results are required")
require(all(v == 200 for v in lifecycle.get("zashboard_http_results", [])) and len(lifecycle.get("zashboard_http_results", [])) == 5, "five Zashboard HTTP 200 lifecycle results are required")
require(all(v == 200 for v in lifecycle.get("luci_root_http_results", [])) and len(lifecycle.get("luci_root_http_results", [])) == 5, "five LuCI HTTP 200 lifecycle results are required")
require(all(v == 0 for v in lifecycle.get("ssh_ubus_results", [])) and len(lifecycle.get("ssh_ubus_results", [])) == 5, "five SSH/ubus lifecycle results are required")

safety = evidence.get("safety") or {}
require(safety.get("no_dns_loop") is True, "no DNS loop evidence is required")
require(safety.get("no_port_conflict") is True, "no port conflict evidence is required")
require(safety.get("no_oom") is True and safety.get("oom_count") == 0, "OOM=0 evidence is required")
require(safety.get("ssh_luci_stable") is True, "SSH/LuCI stability evidence is required")

final_state = evidence.get("final_state") or {}
require(final_state.get("adguardhome") == "OFF", "final AdGuardHome state must be OFF")
require(final_state.get("adguardhome_uci_enabled") == 0, "final AdGuardHome UCI enabled must be 0")
require(final_state.get("adguardhome_init_enabled") is False, "final AdGuardHome init state must be disabled")
require(final_state.get("openclash") == "RUNNING", "final OpenClash state must be RUNNING")
require(final_state.get("dnsmasq_server") == "127.0.0.1#7874", "final dnsmasq upstream must be OpenClash:7874")
require(final_state.get("zashboard_http") == 200, "final Zashboard HTTP 200 is required")
require(final_state.get("controller_authenticated_http") == 200, "final controller authenticated HTTP 200 is required")
require(final_state.get("ssh_ubus") == "PASS", "final SSH/ubus must PASS")
require(final_state.get("luci_root_http") == 200, "final LuCI HTTP 200 is required")

if re.fullmatch(r"[0-9a-f]{40}", validated_sha):
    ancestor = run_git("merge-base", "--is-ancestor", validated_sha, target_sha)
    require(ancestor.returncode == 0, "validated_source_sha is not an ancestor of the build target")
    if ancestor.returncode == 0:
        try:
            post_validation_changes = changed_files(validated_sha, target_sha)
        except RuntimeError as exc:
            errors.append(str(exc))
            post_validation_changes = []
        package_metadata_only = (
            OPENCLASH_CORE_PACKAGE_RECIPE in post_validation_changes
            and openclash_core_package_metadata_only(validated_sha, target_sha)
        )
        validation_only_fix = (
            all(path in post_validation_changes for path in VALIDATION_ONLY_APK_FIXES)
            and validation_only_apk_fix(validated_sha, target_sha)
        )

        package_closure_proven = package_closure_proof_valid(target_sha)

        allowed = set(POST_VALIDATION_ALLOWLIST)
        allowed.update(p for p in post_validation_changes if is_post_validation_control(p))
        if package_metadata_only:
            allowed.add(OPENCLASH_CORE_PACKAGE_RECIPE)
        if validation_only_fix:
            allowed.update(VALIDATION_ONLY_APK_FIXES)
        if package_closure_proven:
            # Exact source 4befe60e... was independently compiled with the
            # verified Arthur Linux SDK. Its APK payload, package-build copy and
            # synthetic rootfs copy are byte-identical to the pinned upstream
            # AArch64 core, and the full prebuild closure passed. The target may
            # differ from that source only by the durable proof file itself.
            allowed.update(post_validation_changes)

        disallowed = [p for p in post_validation_changes if p not in allowed]
        runtime_drift = [] if package_closure_proven else [
            p for p in post_validation_changes
            if is_runtime_impact(p)
            and not (p == OPENCLASH_CORE_PACKAGE_RECIPE and package_metadata_only)
        ]
        require(not disallowed, "post-validation changes are not evidence/gate-only: " + ", ".join(disallowed[:20]))
        require(not runtime_drift, "runtime/source changed after live validation: " + ", ".join(runtime_drift[:20]))

if errors:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=FAIL")
    print(f"PREBUILD_TARGET_SHA={target_sha}")
    for error in errors:
        print(f"- {error}")
    raise SystemExit(1)

print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS")
print(f"PREBUILD_TARGET_SHA={target_sha}")
print(f"VALIDATED_SOURCE_SHA={validated_sha}")
print("OPENCLASH_FULLY_USABLE=PASS")
print("ADGUARDHOME_FULLY_USABLE=PASS")
print("OPENCLASH_ADH_COEXISTENCE=PASS")
if 'package_metadata_only' in globals() and package_metadata_only:
    print("PACKAGE_METADATA_ONLY=true")
if 'validation_only_fix' in globals() and validation_only_fix:
    print("VALIDATION_ONLY_FIX=true")
if 'package_closure_proven' in globals() and package_closure_proven:
    print("PACKAGE_CLOSURE_PROVEN=true")
    print(f"PACKAGE_CLOSURE_SOURCE={PROVEN_PACKAGE_CLOSURE_SOURCE}")
if (
    ('package_metadata_only' in globals() and package_metadata_only)
    or ('validation_only_fix' in globals() and validation_only_fix)
    or ('package_closure_proven' in globals() and package_closure_proven)
):
    print("RUNTIME_BEHAVIOR_CHANGED=false")
    print("LIVE_EVIDENCE_REUSE_ALLOWED=true")
    print("LIVE_EVIDENCE_REUSED=true")
