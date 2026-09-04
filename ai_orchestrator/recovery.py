"""Evidence-driven recovery for the Arthur unattended executor.

Task identity is release_task_id, never a Codex response/thread/session id. This
module only reconciles durable state; it does not perform firmware writes.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from .models import PipelineState


ACTIVE_RUN_STATES = {"queued", "in_progress", "waiting", "requested", "pending"}
TRANSPORT_LOSS_TOKENS = ("404", "response lost", "transport disconnect", "connection reset", "unexpected eof")
SYSUPGRADE_STAGES = {"SYSUPGRADE", "FLASH", "WAIT_DEVICE", "AUTO_FLASH_SAFETY_GATE"}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class ExecutorLease:
    executor_id: str
    acquired_at: str
    heartbeat_at: str
    status: str = "ACTIVE"
    lost_reason: Optional[str] = None

    @classmethod
    def acquire(cls, executor_id: str) -> "ExecutorLease":
        now = _utc_now()
        return cls(executor_id=executor_id, acquired_at=now, heartbeat_at=now)

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "ExecutorLease":
        return cls(
            executor_id=str(raw.get("executor_id") or "unknown"),
            acquired_at=str(raw.get("acquired_at") or _utc_now()),
            heartbeat_at=str(raw.get("heartbeat_at") or _utc_now()),
            status=str(raw.get("status") or "ACTIVE"),
            lost_reason=raw.get("lost_reason"),
        )

    def heartbeat(self) -> None:
        if self.status == "ACTIVE":
            self.heartbeat_at = _utc_now()

    def mark_lost(self, reason: str) -> None:
        self.status = "LOST"
        self.lost_reason = reason
        self.heartbeat_at = _utc_now()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "executor_id": self.executor_id,
            "acquired_at": self.acquired_at,
            "heartbeat_at": self.heartbeat_at,
            "status": self.status,
            "lost_reason": self.lost_reason,
        }


@dataclass
class RecoveryEvidence:
    expected_fingerprint: Optional[str] = None
    candidate_fingerprint: Optional[str] = None
    candidate_run_id: int = 0
    candidate_status: Optional[str] = None
    candidate_conclusion: Optional[str] = None
    candidate_sha256: Optional[str] = None
    sysupgrade_state: Optional[str] = None
    device_evidence_status: Optional[str] = None
    last_verified_stage: Optional[str] = None
    unrecoverable_reason: Optional[str] = None

    @classmethod
    def from_handoff(cls, state: PipelineState) -> "RecoveryEvidence":
        """Collect normalized evidence already persisted by HANDOFF/runtime.

        GitHub Actions, artifact and device probes are expected to persist their
        read-only observations under observability. The supervisor consumes those
        observations rather than replaying any side effect to rediscover state.
        """
        obs = state.observability or {}
        github = obs.get("github_actions") or {}
        artifact = obs.get("artifact") or {}
        device = obs.get("device") or {}
        dedup = obs.get("build_dedup") or {}
        return cls(
            expected_fingerprint=dedup.get("expected_fingerprint") or obs.get("build_fingerprint"),
            candidate_fingerprint=dedup.get("candidate_fingerprint") or artifact.get("build_fingerprint"),
            candidate_run_id=int(github.get("run_id") or state.active_run_id or 0),
            candidate_status=github.get("status"),
            candidate_conclusion=github.get("conclusion"),
            candidate_sha256=artifact.get("sha256") or state.candidate_sha256,
            sysupgrade_state=device.get("sysupgrade_state"),
            device_evidence_status=device.get("status"),
            last_verified_stage=state.last_verified_stage,
            unrecoverable_reason=obs.get("unrecoverable_reason"),
        )


class RecoverySupervisor:
    def __init__(self, state: PipelineState):
        if not state.release_task_id:
            raise ValueError("release_task_id is required for unattended recovery")
        self.state = state
        self.lease: Optional[ExecutorLease] = None
        raw_lease = (state.observability or {}).get("executor_lease")
        if isinstance(raw_lease, dict):
            self.lease = ExecutorLease.from_dict(raw_lease)

    def _persist_lease(self) -> None:
        if self.lease is not None:
            self.state.observability["executor_lease"] = self.lease.to_dict()

    def attach_lease(self, lease: ExecutorLease) -> ExecutorLease:
        self.lease = lease
        self._persist_lease()
        return lease

    def acquire_executor(self, executor_id: str) -> ExecutorLease:
        if self.lease and self.lease.status == "ACTIVE":
            raise RuntimeError("ACTIVE_EXECUTOR_LEASE_EXISTS")
        return self.attach_lease(ExecutorLease.acquire(executor_id))

    def mark_executor_lost(self, reason: str) -> None:
        if self.lease is None:
            self.lease = ExecutorLease.acquire("unknown-executor")
        self.lease.mark_lost(reason)
        self._persist_lease()
        self.state.observability["last_executor_loss"] = {
            "reason": reason,
            "at": _utc_now(),
        }

    def handle_transport_loss(self, reason: str, evidence: RecoveryEvidence) -> PipelineState:
        lowered = reason.lower()
        if not any(token in lowered for token in TRANSPORT_LOSS_TOKENS):
            raise ValueError("reason is not a recognized transport/session loss")
        self.mark_executor_lost(reason)
        return self.reconcile(evidence)

    def reconcile(self, evidence: RecoveryEvidence) -> PipelineState:
        # A genuinely contradictory/unsafe observation is the only terminal block.
        if evidence.unrecoverable_reason:
            self.state.terminal_state = "SAFETY_BLOCKED"
            self.state.next_action = "BLOCKED"
            self.state.observability["recovery_block"] = {
                "evidence": evidence.unrecoverable_reason,
                "next_action": "MANUAL_SAFETY_DIAGNOSIS",
                "at": _utc_now(),
            }
            return self.state

        # Flash/write may already have occurred. Never replay sysupgrade merely
        # because the previous executor/session vanished.
        if (
            self.state.current_stage in SYSUPGRADE_STAGES
            or self.state.next_action in {"SYSUPGRADE", "FLASH"}
        ) and (
            (evidence.sysupgrade_state or "unknown").lower() == "unknown"
            or (evidence.device_evidence_status or "unknown").lower() == "unknown"
        ):
            self.state.next_action = "REAL_DEVICE_RECONCILE"
            self.state.phase = "REAL_DEVICE_RECONCILE"
            self.state.current_stage = "REAL_DEVICE_RECONCILE"
            self.state.observability["recovery_decision"] = {
                "action": "REAL_DEVICE_RECONCILE",
                "reason": "sysupgrade/device state unknown; blind second flash forbidden",
                "at": _utc_now(),
            }
            return self.state

        expected = evidence.expected_fingerprint
        actual = evidence.candidate_fingerprint
        fingerprint_matches = bool(expected and actual and expected == actual)
        status = str(evidence.candidate_status or "").lower()
        conclusion = str(evidence.candidate_conclusion or "").lower()

        if fingerprint_matches and status in ACTIVE_RUN_STATES:
            self.state.active_run_id = int(evidence.candidate_run_id or self.state.active_run_id or 0)
            self.state.next_action = "WATCH_EXISTING_RUN"
            self.state.current_stage = "CANDIDATE_WAIT"
            self.state.phase = "CANDIDATE_WAIT"
            self.state.observability["recovery_decision"] = {
                "action": "WATCH_EXISTING_RUN",
                "run_id": self.state.active_run_id,
                "at": _utc_now(),
            }
            return self.state

        if fingerprint_matches and status == "completed" and conclusion == "success":
            self.state.active_run_id = int(evidence.candidate_run_id or self.state.active_run_id or 0)
            if evidence.candidate_sha256:
                self.state.candidate_sha256 = evidence.candidate_sha256
            self.state.next_action = "REUSE_ARTIFACT"
            self.state.current_stage = "CANDIDATE_VERIFIED"
            self.state.phase = "CANDIDATE_VERIFIED"
            self.state.last_verified_stage = "CANDIDATE_VERIFIED"
            self.state.observability["recovery_decision"] = {
                "action": "REUSE_ARTIFACT",
                "run_id": self.state.active_run_id,
                "candidate_sha256": self.state.candidate_sha256,
                "at": _utc_now(),
            }
            return self.state

        # If no side-effect ambiguity exists, resume from the durable checkpoint.
        self.state.next_action = self.state.next_action or self.state.current_stage or self.state.phase
        self.state.observability["recovery_decision"] = {
            "action": self.state.next_action,
            "reason": "resume durable HANDOFF checkpoint",
            "at": _utc_now(),
        }
        return self.state
