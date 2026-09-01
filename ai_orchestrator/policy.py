from dataclasses import dataclass
from enum import Enum
import re

from .models import ActionKind, GPTDecision, HumanGate, TerminalState


class DecisionValidationError(ValueError):
    pass


class PolicyRoute(str, Enum):
    SAFE_AUTO = "SAFE_AUTO"
    RECOVERABLE = "RECOVERABLE"
    HUMAN_GATE = "HUMAN_GATE"
    TERMINAL = "TERMINAL"


@dataclass
class PolicyOutcome:
    route: PolicyRoute
    decision: GPTDecision
    human_gate: HumanGate = None


AUTO_FLASH_REASON_CODES = {
    "AUTO_FLASH_SAFETY_GATE",
    "AUTO_ROLLBACK_SAFETY_GATE",
}
AUTO_FLASH_BOOLEAN_CHECKS = (
    "device_identity",
    "mac_match",
    "model_match",
    "storage_layout_verified",
    "candidate_complete",
    "candidate_size_match",
    "ssh_control_channel",
    "plugins_22",
    "argon",
    "kucat",
    "known_good_available",
    "rollback_ready",
    "rollback_sha256_verified",
)


def validate_decision(raw):
    try:
        decision = raw if isinstance(raw, GPTDecision) else GPTDecision.from_dict(raw)
        _validate_contract(decision)
        return decision
    except (TypeError, ValueError) as exc:
        raise DecisionValidationError(str(exc))


def policy_gate(decision):
    decision = validate_decision(decision)
    if decision.action == ActionKind.SAFE_AUTO:
        return PolicyOutcome(PolicyRoute.SAFE_AUTO, decision)
    if decision.action == ActionKind.RECOVERABLE:
        return PolicyOutcome(PolicyRoute.RECOVERABLE, decision)
    if decision.action == ActionKind.HUMAN_GATE:
        return PolicyOutcome(PolicyRoute.HUMAN_GATE, decision, decision.human_gate)
    if decision.action == ActionKind.TERMINAL:
        return PolicyOutcome(PolicyRoute.TERMINAL, decision)
    raise DecisionValidationError("unsupported policy action")


def _validate_contract(decision):
    if decision.action in (ActionKind.SAFE_AUTO, ActionKind.RECOVERABLE) and not decision.next_codex_prompt:
        raise ValueError("automatic decisions require next_codex_prompt")
    if decision.action == ActionKind.SAFE_AUTO and decision.reason_code in AUTO_FLASH_REASON_CODES:
        _validate_auto_flash_safety_gate(decision)
    if decision.action == ActionKind.HUMAN_GATE:
        if decision.human_gate is None:
            raise ValueError("human decision requires a whitelisted human_gate")
        if not decision.evidence:
            raise ValueError("human gate requires evidence")
    if decision.action == ActionKind.TERMINAL:
        if decision.terminal_state is None:
            raise ValueError("terminal decision requires terminal_state")
        if decision.terminal_state == TerminalState.PRODUCTION_RELEASED and decision.human_gate:
            raise ValueError("released decision cannot carry a human gate")
    if decision.reason_code == "AUTH_REQUIRED":
        required = {
            "auth_resource": decision.auth_resource,
            "provider": decision.provider,
            "verification_error": decision.verification_error,
        }
        missing = [name for name, value in required.items() if not value]
        if missing or not decision.credential_discovery_failed or not decision.evidence:
            raise ValueError("AUTH_REQUIRED requires auth_resource, provider, verification_error, evidence, and failed discovery proof")
        if decision.human_gate != HumanGate.NEW_CREDENTIAL_PROVISIONING:
            raise ValueError("AUTH_REQUIRED must use NEW_CREDENTIAL_PROVISIONING")


def _validate_auto_flash_safety_gate(decision):
    metadata = decision.metadata
    candidate = metadata.get("candidate")
    checks = metadata.get("safety_gate")
    if not isinstance(candidate, dict) or not isinstance(checks, dict):
        raise ValueError("AUTO_FLASH_SAFETY_GATE requires candidate and safety_gate evidence")

    required_candidate = (
        "filename",
        "sha256",
        "size_bytes",
        "target",
        "profile",
        "build_report",
        "package_report",
        "theme_report",
        "lan_static_report",
        "rollback_report",
        "flash_manifest",
    )
    if any(not candidate.get(name) for name in required_candidate):
        raise ValueError("AUTO_FLASH_SAFETY_GATE requires a complete candidate manifest")
    if candidate.get("target") != "qualcommax/ipq60xx":
        raise ValueError("auto-flash candidate target mismatch")
    if candidate.get("profile") != "jdcloud_re-ss-01":
        raise ValueError("auto-flash candidate profile mismatch")
    if not isinstance(candidate.get("size_bytes"), int) or candidate["size_bytes"] <= 0:
        raise ValueError("auto-flash candidate size must be a positive integer")

    for check in AUTO_FLASH_BOOLEAN_CHECKS:
        if checks.get(check) is not True:
            raise ValueError("AUTO_FLASH_SAFETY_GATE check failed: %s" % check)

    digests = [candidate.get("sha256"), checks.get("cloud_sha256"), checks.get("local_sha256"), checks.get("remote_sha256")]
    if any(not isinstance(digest, str) or not re.match(r"^[0-9a-fA-F]{64}$", digest) for digest in digests):
        raise ValueError("AUTO_FLASH_SAFETY_GATE requires valid cloud/local/remote SHA256 values")
    if len({digest.lower() for digest in digests}) != 1:
        raise ValueError("AUTO_FLASH_SAFETY_GATE requires matching cloud/local/remote SHA256 values")

    if checks.get("expected_post_flash_lan") != "192.168.6.1":
        raise ValueError("auto-flash expected LAN mismatch")
    recovery_address = checks.get("current_recovery_address")
    if not isinstance(recovery_address, str) or not recovery_address:
        raise ValueError("AUTO_FLASH_SAFETY_GATE requires current recovery address evidence")
    if recovery_address == "192.168.1.1" and checks.get("recovery_address_classification") != "KNOWN_LAN_REGRESSION":
        raise ValueError("192.168.1.1 requires KNOWN_LAN_REGRESSION classification")
