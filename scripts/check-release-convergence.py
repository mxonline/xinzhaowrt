#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"RELEASE_CONVERGENCE_MISSING={name}")
    return value


def require_hex64(name: str) -> str:
    value = require(name).lower()
    if not HEX64.fullmatch(value):
        raise SystemExit(f"RELEASE_CONVERGENCE_INVALID_{name}={value}")
    return value


def main() -> int:
    failure_set_state = require("FAILURE_SET_STATE")
    failure_set_fingerprint = require_hex64("FAILURE_SET_FINGERPRINT")
    verification_contract_fingerprint = require_hex64("VERIFICATION_CONTRACT_FINGERPRINT")
    rootfs_offline_passed = require("ROOTFS_OFFLINE_PASSED").lower()
    contract_gap_state = require("CONTRACT_GAP_STATE")
    firmware_input_fingerprint = require_hex64("FIRMWARE_INPUT_FINGERPRINT")

    if failure_set_state != "RESOLVED":
        raise SystemExit(f"BUILD_DENIED_FAILURE_SET_STATE={failure_set_state}")
    if rootfs_offline_passed != "true":
        raise SystemExit("BUILD_DENIED_ROOTFS_OFFLINE_NOT_PASS")
    if contract_gap_state != "NONE":
        raise SystemExit(f"BUILD_DENIED_CONTRACT_GAP={contract_gap_state}")

    probe = subprocess.run(
        ["bash", "scripts/get-firmware-input-fingerprint.sh"],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if probe.returncode != 0:
        sys.stderr.write(probe.stderr)
        raise SystemExit("BUILD_DENIED_FIRMWARE_INPUT_FINGERPRINT_UNAVAILABLE")
    actual = probe.stdout.strip().lower()
    if not HEX64.fullmatch(actual):
        raise SystemExit(f"BUILD_DENIED_FIRMWARE_INPUT_FINGERPRINT_INVALID={actual}")
    if actual != firmware_input_fingerprint:
        raise SystemExit(
            "BUILD_DENIED_FIRMWARE_INPUT_DRIFT "
            f"expected={firmware_input_fingerprint} actual={actual}"
        )

    print("RELEASE_CONVERGENCE=PASS")
    print(f"failure_set_state={failure_set_state}")
    print(f"failure_set_fingerprint={failure_set_fingerprint}")
    print(f"verification_contract_fingerprint={verification_contract_fingerprint}")
    print(f"firmware_input_fingerprint={firmware_input_fingerprint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
