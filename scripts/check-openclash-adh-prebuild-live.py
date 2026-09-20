#!/usr/bin/env python3
"""Verify the immutable Arthur OpenClash/AdGuardHome live-prebuild evidence."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def fail(messages: list[str]) -> int:
    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=FAIL")
    for message in messages:
        print(f"- {message}")
    return 1


def git_head() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.STDOUT
    ).strip()


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    requested = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    try:
        actual_head = git_head()
        requested_head = subprocess.check_output(
            ["git", "rev-parse", requested],
            text=True,
            stderr=subprocess.STDOUT,
        ).strip()
    except subprocess.CalledProcessError as exc:
        return fail([f"cannot resolve source revision {requested}: {exc.output.strip()}"])

    evidence_path = root / "production" / "evidence" / "prebuild-openclash-adh-live.json"
    if not evidence_path.is_file():
        return fail([f"missing evidence: {evidence_path}"])

    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fail([f"cannot parse evidence: {exc}"])

    errors: list[str] = []

    def equal(path: str, actual: object, expected: object) -> None:
        if actual != expected:
            errors.append(f"{path} expected {expected!r}, got {actual!r}")

    def true(path: str, actual: object) -> None:
        if actual is not True:
            errors.append(f"{path} must be true")

    equal("requested revision", requested_head, actual_head)
    equal("evidence.gate", evidence.get("gate"), "PREBUILD_OPENCLASH_ADH_LIVE_GATE")
    equal("evidence.status", evidence.get("status"), "PASS")
    equal("evidence.mode", evidence.get("mode"), "LIVE_NON_DISRUPTIVE")
    equal("evidence.validated_source_sha", evidence.get("validated_source_sha"), actual_head)
    equal("device.address", evidence.get("device", {}).get("address"), "192.168.6.1")
    equal("device.firmware", evidence.get("device", {}).get("firmware"), "v0.1.5")

    restrictions = evidence.get("restrictions", {})
    true("restrictions.build_forbidden", restrictions.get("build_forbidden"))
    true("restrictions.release_forbidden", restrictions.get("release_forbidden"))
    true("restrictions.sysupgrade_forbidden", restrictions.get("sysupgrade_forbidden"))
    equal("restrictions.build_executed", restrictions.get("build_executed"), False)
    equal("restrictions.release_executed", restrictions.get("release_executed"), False)
    equal("restrictions.sysupgrade_executed", restrictions.get("sysupgrade_executed"), False)

    live = evidence.get("live_runtime_prebuild", {})
    equal("live_runtime_prebuild.status", live.get("status"), "PASS")

    equal("openclash.fully_usable", evidence.get("openclash_fully_usable"), "PASS")
    equal("adguardhome.fully_usable", evidence.get("adguardhome_fully_usable"), "PASS")
    equal("coexistence", evidence.get("openclash_adh_coexistence"), "PASS")

    fake_ip = evidence.get("fake_ip_runtime", {})
    true("fake_ip_runtime.consistent", fake_ip.get("consistent"))
    equal("fake_ip_runtime.mode", fake_ip.get("runtime_mode"), "fake-ip")
    equal("fake_ip_runtime.zashboard", fake_ip.get("external_ui_name"), "zashboard")

    lifecycle = evidence.get("lifecycle", {})
    equal("lifecycle.sequence", lifecycle.get("sequence"), "OFF -> ON -> OFF -> ON -> OFF")
    equal("lifecycle.status", lifecycle.get("status"), "PASS")

    final_state = evidence.get("final_state", {})
    equal("final_state.adguardhome", final_state.get("adguardhome"), "OFF")
    equal("final_state.openclash", final_state.get("openclash"), "RUNNING")
    equal("final_state.dnsmasq_server", final_state.get("dnsmasq_server"), "127.0.0.1#7874")

    if errors:
        return fail(errors)

    print("PREBUILD_OPENCLASH_ADH_LIVE_GATE=PASS")
    print("OPENCLASH_FULLY_USABLE=PASS")
    print("ADGUARDHOME_FULLY_USABLE=PASS")
    print("OPENCLASH_ADH_COEXISTENCE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
