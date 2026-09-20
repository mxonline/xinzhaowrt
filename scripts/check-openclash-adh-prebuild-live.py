#!/usr/bin/env python3
"""Fail-closed prebuild gate for Arthur runtime-affecting firmware changes.

A Candidate build is allowed only after the currently running Arthur has
machine evidence proving OpenClash and AdGuardHome work together for the
validated source.  Evidence is bound to the validated source commit; only the
durable evidence file itself may be committed after that source before Build.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = "production/evidence/prebuild-openclash-adh-live.json"

REQUIRED_MARKERS = (
    "OPENCLASH_FULLY_USABLE",
    "ADGUARDHOME_FULLY_USABLE",
    "OPENCLASH_ADH_COEXISTENCE",
    "OPENCLASH_CONTROLLER",
    "ZASHBOARD_RUNTIME",
    "OPENCLASH_RUNTIME_CONFIG_PARITY",
    "OPENCLASH_DNS_RUNTIME",
    "OPENCLASH_ADH_DNS_CHAIN",
    "REAL_PROXY_TRAFFIC",
    "ADGUARDHOME_FILTERING",
    "ADGUARDHOME_QUERY_LOG",
    "NO_DNS_LOOP",
    "NO_PORT_CONFLICT",
    "NO_OOM_OR_MANAGEMENT_PLANE_LOSS",
    "ADH_DISABLE_LEAVES_OPENCLASH_WORKING",
    "ADH_REENABLE_RESTORES_CHAIN",
    "FINAL_ADH_DEFAULT_OFF",
)

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


def run_git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def fail(message: str) -> None:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=FAIL")
    print(f"BLOCKED: {message}")
    raise SystemExit(1)


def show_text(commit: str, path: str) -> str:
    proc = run_git("show", f"{commit}:{path}", check=False)
    if proc.returncode != 0:
        fail(f"missing {path} at {commit}: {proc.stderr.strip()}")
    return proc.stdout


def changed_files(base: str, head: str) -> list[str]:
    proc = run_git("diff", "--name-only", f"{base}..{head}", check=False)
    if proc.returncode != 0:
        fail(f"cannot diff {base}..{head}: {proc.stderr.strip()}")
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def is_runtime_impact(path: str) -> bool:
    if path in RUNTIME_FILES:
        return True
    if path.startswith(RUNTIME_PREFIXES):
        return True
    lowered = path.lower()
    return any(token in lowered for token in ("openclash", "adguardhome", "dns-coexist"))


target = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
target_proc = run_git("rev-parse", target, check=False)
if target_proc.returncode != 0:
    fail(f"target commit is unavailable: {target}")
target_sha = target_proc.stdout.strip()

try:
    known_good = json.loads(show_text(target_sha, "production/known-good.json"))
except json.JSONDecodeError as exc:
    fail(f"invalid production/known-good.json at target: {exc}")

baseline = str(known_good.get("project_commit") or known_good.get("source_commit") or "")
if not re.fullmatch(r"[0-9a-f]{40}", baseline):
    fail("Known-Good baseline project/source commit is missing or invalid")

impact = [path for path in changed_files(baseline, target_sha) if is_runtime_impact(path)]
if not impact:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=SKIPPED_NO_RUNTIME_IMPACT")
    print(f"PREBUILD_TARGET_SHA={target_sha}")
    raise SystemExit(0)

try:
    evidence = json.loads(show_text(target_sha, EVIDENCE_PATH))
except json.JSONDecodeError as exc:
    fail(f"invalid {EVIDENCE_PATH}: {exc}")

errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


require(evidence.get("schema_version") == 1, "schema_version must be 1")
require(str(evidence.get("mode") or "") == "LIVE_RUNTIME_PREBUILD", "mode must be LIVE_RUNTIME_PREBUILD")
require(str(evidence.get("status") or "").upper() == "PASS", "status must be PASS")
require(evidence.get("safe_live_validation") is True, "safe_live_validation must be true")
require(str(evidence.get("device") or "") == "jdcloud_re-ss-01", "device must be jdcloud_re-ss-01")
require(bool(str(evidence.get("observed_at") or "").strip()), "observed_at is required")
require(isinstance(evidence.get("errors"), list) and len(evidence.get("errors") or []) == 0, "errors must be an empty list")

validated_sha = str(evidence.get("validated_source_sha") or "")
require(bool(re.fullmatch(r"[0-9a-f]{40}", validated_sha)), "validated_source_sha must be a full commit SHA")

markers = evidence.get("markers") or {}
for marker in REQUIRED_MARKERS:
    require(markers.get(marker) == "PASS", f"{marker}=PASS is required")

final_state = evidence.get("final_state") or {}
require(final_state.get("adguardhome_enabled") is False, "final_state.adguardhome_enabled must be false")
require(final_state.get("openclash_running") is True, "final_state.openclash_running must be true")

if re.fullmatch(r"[0-9a-f]{40}", validated_sha):
    ancestor = run_git("merge-base", "--is-ancestor", validated_sha, target_sha, check=False)
    require(ancestor.returncode == 0, "validated_source_sha is not an ancestor of the build target")
    if ancestor.returncode == 0:
        post_validation_changes = changed_files(validated_sha, target_sha)
        disallowed = [path for path in post_validation_changes if path != EVIDENCE_PATH]
        require(
            not disallowed,
            "source changed after live validation: " + ", ".join(disallowed[:20]),
        )

if errors:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=FAIL")
    print(f"PREBUILD_TARGET_SHA={target_sha}")
    print("RUNTIME_IMPACT_FILES=" + ",".join(impact[:40]))
    for error in errors:
        print(f"- {error}")
    raise SystemExit(1)

print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS")
print(f"PREBUILD_TARGET_SHA={target_sha}")
print(f"VALIDATED_SOURCE_SHA={validated_sha}")
print("OPENCLASH_FULLY_USABLE=PASS")
print("ADGUARDHOME_FULLY_USABLE=PASS")
print("OPENCLASH_ADH_COEXISTENCE=PASS")
