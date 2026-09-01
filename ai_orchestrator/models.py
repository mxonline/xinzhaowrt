from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional


class ActionKind(str, Enum):
    SAFE_AUTO = "SAFE_AUTO"
    RECOVERABLE = "RECOVERABLE"
    HUMAN_GATE = "HUMAN_GATE"
    TERMINAL = "TERMINAL"


class HumanGate(str, Enum):
    NEW_CREDENTIAL_PROVISIONING = "NEW_CREDENTIAL_PROVISIONING"
    UNKNOWN_DEVICE_IDENTITY = "UNKNOWN_DEVICE_IDENTITY"
    NO_SAFE_ROLLBACK = "NO_SAFE_ROLLBACK"
    UNRECOVERABLE_IRREVERSIBLE_OPERATION = "UNRECOVERABLE_IRREVERSIBLE_OPERATION"


class TerminalState(str, Enum):
    PRODUCTION_RELEASED = "PRODUCTION_RELEASED"
    CREDENTIAL_REQUIRED = "CREDENTIAL_REQUIRED"
    SAFETY_BLOCKED = "SAFETY_BLOCKED"


@dataclass
class GPTDecision:
    action: ActionKind
    reason_code: str
    summary: str
    next_codex_prompt: Optional[str] = None
    human_gate: Optional[HumanGate] = None
    evidence: List[str] = field(default_factory=list)
    terminal_state: Optional[TerminalState] = None
    auth_resource: Optional[str] = None
    provider: Optional[str] = None
    verification_error: Optional[str] = None
    credential_discovery_failed: bool = False
    metadata: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "GPTDecision":
        if not isinstance(raw, dict):
            raise ValueError("controller decision must be an object")
        action = _enum_value(ActionKind, raw.get("action"), "action")
        reason_code = _string(raw.get("reason_code"), "reason_code")
        summary = _string(raw.get("summary"), "summary")
        next_prompt = raw.get("next_codex_prompt")
        if next_prompt is not None and (not isinstance(next_prompt, str) or not next_prompt.strip()):
            raise ValueError("next_codex_prompt must be a non-empty string when supplied")
        evidence = raw.get("evidence", [])
        if not isinstance(evidence, list) or any(not isinstance(item, str) or not item.strip() for item in evidence):
            raise ValueError("evidence must be a list of non-empty strings")
        human_gate = raw.get("human_gate")
        if human_gate is not None:
            human_gate = _enum_value(HumanGate, human_gate, "human_gate")
        terminal_state = raw.get("terminal_state")
        if terminal_state is not None:
            terminal_state = _enum_value(TerminalState, terminal_state, "terminal_state")
        metadata = raw.get("metadata", {})
        if not isinstance(metadata, dict):
            raise ValueError("metadata must be an object")
        credential_failed = raw.get("credential_discovery_failed", False)
        if not isinstance(credential_failed, bool):
            raise ValueError("credential_discovery_failed must be boolean")
        return cls(
            action=action,
            reason_code=reason_code,
            summary=summary,
            next_codex_prompt=next_prompt,
            human_gate=human_gate,
            evidence=evidence,
            terminal_state=terminal_state,
            auth_resource=_optional_string(raw.get("auth_resource"), "auth_resource"),
            provider=_optional_string(raw.get("provider"), "provider"),
            verification_error=_optional_string(raw.get("verification_error"), "verification_error"),
            credential_discovery_failed=credential_failed,
            metadata=metadata,
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "action": self.action.value,
            "reason_code": self.reason_code,
            "summary": self.summary,
            "next_codex_prompt": self.next_codex_prompt,
            "human_gate": self.human_gate.value if self.human_gate else None,
            "evidence": list(self.evidence),
            "terminal_state": self.terminal_state.value if self.terminal_state else None,
            "auth_resource": self.auth_resource,
            "provider": self.provider,
            "verification_error": self.verification_error,
            "credential_discovery_failed": self.credential_discovery_failed,
            "metadata": dict(self.metadata),
        }


@dataclass
class CodexResult:
    turn_id: str
    final_response: str
    status: str = "completed"
    executor_thread_id: Optional[str] = None
    items: List[Dict[str, Any]] = field(default_factory=list)
    evidence: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "turn_id": self.turn_id,
            "final_response": self.final_response,
            "status": self.status,
            "executor_thread_id": self.executor_thread_id,
            "items": list(self.items),
            "evidence": list(self.evidence),
        }


@dataclass
class PipelineState:
    request_id: str
    device: str
    phase: str
    next_codex_prompt: Optional[str]
    terminal_state: Optional[str] = None
    executor_thread_id: Optional[str] = None
    controller_thread_id: Optional[str] = None
    responses_conversation_id: Optional[str] = None
    pending_human_gate: Optional[str] = None
    candidate: Dict[str, Any] = field(default_factory=dict)
    known_good: Dict[str, Any] = field(default_factory=dict)
    turn_count: int = 0
    last_result: Optional[Dict[str, Any]] = None
    last_decision: Optional[Dict[str, Any]] = None
    preflight: Dict[str, Any] = field(default_factory=dict)
    stop_requested: bool = False
    observability: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": "2.0",
            "request_id": self.request_id,
            "device": self.device,
            "phase": self.phase,
            "next_codex_prompt": self.next_codex_prompt,
            "terminal_state": self.terminal_state,
            "executor_thread_id": self.executor_thread_id,
            "controller_thread_id": self.controller_thread_id,
            "responses_conversation_id": self.responses_conversation_id,
            "pending_human_gate": self.pending_human_gate,
            "candidate": dict(self.candidate),
            "known_good": dict(self.known_good),
            "turn_count": self.turn_count,
            "last_result": self.last_result,
            "last_decision": self.last_decision,
            "preflight": dict(self.preflight),
            "stop_requested": self.stop_requested,
            "observability": dict(self.observability),
        }

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "PipelineState":
        values = dict(raw)
        values.pop("schema_version", None)
        return cls(
            request_id=values["request_id"],
            device=values["device"],
            phase=values["phase"],
            next_codex_prompt=values.get("next_codex_prompt"),
            terminal_state=values.get("terminal_state"),
            executor_thread_id=values.get("executor_thread_id"),
            controller_thread_id=values.get("controller_thread_id"),
            responses_conversation_id=values.get("responses_conversation_id"),
            pending_human_gate=values.get("pending_human_gate"),
            candidate=values.get("candidate", {}),
            known_good=values.get("known_good", {}),
            turn_count=int(values.get("turn_count", 0)),
            last_result=values.get("last_result"),
            last_decision=values.get("last_decision"),
            preflight=values.get("preflight", {}),
            stop_requested=bool(values.get("stop_requested", False)),
            observability=values.get("observability", {}),
        )


def _string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("%s must be a non-empty string" % name)
    return value.strip()


def _optional_string(value: Any, name: str) -> Optional[str]:
    if value is None:
        return None
    return _string(value, name)


def _enum_value(enum_type, value: Any, name: str):
    if not isinstance(value, str):
        raise ValueError("%s must be a string" % name)
    try:
        return enum_type(value)
    except ValueError:
        raise ValueError("unsupported %s: %s" % (name, value))
