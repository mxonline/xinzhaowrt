import re
from typing import Any

RISK = {"low", "medium", "high", "critical"}
LAYERS = {"core", "domain", "project", "vendor"}
PERMISSIONS = {"read", "write", "network", "git", "device", "execute"}
STAGE_STATUS = {"NOT_STARTED", "IN_PROGRESS", "DONE", "VERIFIED", "BLOCKED", "FAILED", "UNKNOWN"}
EVIDENCE_STATUS = {"PASS", "FAIL", "BLOCKED", "INFO"}
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SKILL_ID = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$")


def _require(data: dict[str, Any], names: list[str], errors: list[str]) -> None:
    for name in names:
        if name not in data:
            errors.append(f"missing required field: {name}")


def _string_list(data: dict[str, Any], names: list[str], errors: list[str]) -> None:
    for name in names:
        value = data.get(name)
        if value is not None and (not isinstance(value, list) or any(not isinstance(item, str) for item in value)):
            errors.append(f"{name} must be a list of strings")


def _validate_skill(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = [
        "id", "version", "layer", "triggers", "non_triggers", "inputs",
        "preconditions", "permissions", "risk", "implementation", "evidence",
        "verification", "failure_handling", "fallback",
    ]
    _require(data, required, errors)
    _string_list(data, ["triggers", "non_triggers", "inputs", "preconditions", "permissions", "evidence", "verification"], errors)

    skill_id = data.get("id")
    if skill_id is not None and (not isinstance(skill_id, str) or not SKILL_ID.fullmatch(skill_id)):
        errors.append("id must be a dotted or hyphenated lowercase skill id")
    version = data.get("version")
    if version is not None and (not isinstance(version, str) or not SEMVER.fullmatch(version)):
        errors.append("version must be semantic x.y.z")
    if data.get("layer") not in LAYERS:
        errors.append("layer is invalid")
    if data.get("risk") not in RISK:
        errors.append("risk is invalid")

    permissions = data.get("permissions")
    if isinstance(permissions, list):
        unknown = sorted(set(permissions) - PERMISSIONS)
        if unknown:
            errors.append(f"permissions contain unknown values: {', '.join(unknown)}")

    implementation = data.get("implementation")
    if not isinstance(implementation, dict):
        errors.append("implementation must be an object")
    else:
        if implementation.get("type") not in {"local", "vendor", "adapter"}:
            errors.append("implementation.type is invalid")
        if not isinstance(implementation.get("binding"), str) or not implementation.get("binding"):
            errors.append("implementation.binding is required")

    for field in ("failure_handling", "fallback"):
        if field in data and not isinstance(data[field], str):
            errors.append(f"{field} must be a string")
    return errors


def _validate_task_packet(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = ["task_id", "goal", "project", "domain", "current_state", "requested_action", "constraints", "risk", "resume_state"]
    _require(data, required, errors)
    for field in ("task_id", "goal", "project", "domain", "current_state", "requested_action"):
        if field in data and (not isinstance(data[field], str) or not data[field]):
            errors.append(f"{field} must be a non-empty string")
    _string_list(data, ["constraints"], errors)
    if data.get("risk") not in RISK:
        errors.append("risk is invalid")
    if "resume_state" in data and not isinstance(data["resume_state"], dict):
        errors.append("resume_state must be an object")
    return errors


def _validate_handoff(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = ["task_id", "current_stage", "stage_status", "verified_stages", "failed_or_blocked_stage", "evidence", "next_skill", "rollback_target", "last_updated"]
    _require(data, required, errors)
    _string_list(data, ["verified_stages", "evidence"], errors)
    if data.get("stage_status") not in STAGE_STATUS:
        errors.append("stage_status is invalid")
    for field in ("task_id", "current_stage", "next_skill", "rollback_target", "last_updated"):
        if field in data and not isinstance(data[field], str):
            errors.append(f"{field} must be a string")
    if "failed_or_blocked_stage" in data and data["failed_or_blocked_stage"] is not None and not isinstance(data["failed_or_blocked_stage"], str):
        errors.append("failed_or_blocked_stage must be string or null")
    return errors


def _validate_evidence(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = ["task_id", "skill_id", "status", "artifacts", "checks", "timestamp"]
    _require(data, required, errors)
    if data.get("status") not in EVIDENCE_STATUS:
        errors.append("status is invalid")
    if "artifacts" in data and not isinstance(data["artifacts"], list):
        errors.append("artifacts must be a list")
    checks = data.get("checks")
    if checks is not None:
        if not isinstance(checks, list):
            errors.append("checks must be a list")
        else:
            for check in checks:
                if not isinstance(check, dict) or check.get("status") not in EVIDENCE_STATUS or not isinstance(check.get("name"), str):
                    errors.append("each check requires name and valid status")
                    break
    return errors


def validate_document(kind: str, data: dict[str, Any]) -> list[str]:
    if not isinstance(data, dict):
        return ["document must be an object"]
    validators = {
        "skill": _validate_skill,
        "task_packet": _validate_task_packet,
        "handoff": _validate_handoff,
        "evidence": _validate_evidence,
    }
    validator = validators.get(kind)
    if validator is None:
        return [f"unknown document kind: {kind}"]
    return validator(data)
