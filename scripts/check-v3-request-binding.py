#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path


def need(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"V3_REQUEST_BINDING_MISSING_ENV={name}")
    return value


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-v3-request-binding.py <request-json>")
    path = Path(sys.argv[1])
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"V3_REQUEST_BINDING_INVALID_JSON={exc}")

    expected = {
        "mode": need("UPDATE_MODE"),
        "source_ref": need("GITHUB_REF_NAME"),
        "source_sha": need("GITHUB_SHA"),
        "failure_set_state": need("FAILURE_SET_STATE"),
        "failure_set_fingerprint": need("FAILURE_SET_FINGERPRINT"),
        "verification_contract_fingerprint": need("VERIFICATION_CONTRACT_FINGERPRINT"),
        "rootfs_offline_passed": need("ROOTFS_OFFLINE_PASSED").lower(),
        "contract_gap_state": need("CONTRACT_GAP_STATE"),
        "firmware_input_fingerprint": need("FIRMWARE_INPUT_FINGERPRINT"),
    }

    for key, wanted in expected.items():
        if key not in data:
            raise SystemExit(f"V3_REQUEST_BINDING_FIELD_MISSING={key}")
        actual = str(data.get(key, ""))
        if key == "rootfs_offline_passed":
            actual = actual.lower()
        if actual != wanted:
            raise SystemExit(
                f"V3_REQUEST_BINDING_MISMATCH field={key} expected={wanted} actual={actual}"
            )

    request_id = str(data.get("request_id") or "")
    if not request_id:
        raise SystemExit("V3_REQUEST_BINDING_FIELD_MISSING=request_id")
    print(
        "V3_REQUEST_CONVERGENCE_BINDING=PASS "
        f"request_id={request_id} source_ref={expected['source_ref']} source_sha={expected['source_sha']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
