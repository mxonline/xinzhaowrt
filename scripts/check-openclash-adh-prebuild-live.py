#!/usr/bin/env python3
"""Trusted fail-closed Arthur prebuild live gate.

This checker runs from the default branch but validates the exact Candidate
commit supplied on argv. It accepts the durable LIVE_NON_DISRUPTIVE evidence
schema produced by the Arthur live-repair flow and rejects any firmware/runtime
source drift after the validated source commit.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = "production/evidence/prebuild-openclash-adh-live.json"

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
    "scripts/check-openclash-adh-prebuild-live.py",
    OPENCLASH_CORE_BUNDLE_TEST,
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
    "scripts/stage-openclash-core.sh",
    "scripts/patch-adguardhome-coexistence.py",
    "production/openclash-adguardhome-coexistence.json",
}


def run_git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        text=True,
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
    if path in POST_VALIDATION_ALLOWLIST:
        return False
    if path in RUNTIME_FILES or path.startswith(RUNTIME_PREFIXES):
        return True
    lowered = path.lower()
    return any(token in lowered for token in ("openclash", "adguardhome", "dns-coexist"))


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
except (RuntimeError, json.JSONDecodeError) as exc:
    raise SystemExit(fail([str(exc)]))


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


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

        allowed = set(POST_VALIDATION_ALLOWLIST)
        if package_metadata_only:
            allowed.add(OPENCLASH_CORE_PACKAGE_RECIPE)
        if validation_only_fix:
            allowed.update(VALIDATION_ONLY_APK_FIXES)

        disallowed = [p for p in post_validation_changes if p not in allowed]
        runtime_drift = [
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
if (
    ('package_metadata_only' in globals() and package_metadata_only)
    or ('validation_only_fix' in globals() and validation_only_fix)
):
    print("RUNTIME_BEHAVIOR_CHANGED=false")
    print("LIVE_EVIDENCE_REUSE_ALLOWED=true")
    print("LIVE_EVIDENCE_REUSED=true")
