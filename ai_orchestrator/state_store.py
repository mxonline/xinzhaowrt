import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from .models import PipelineState
from .observability import atomic_json_write


class StateStore:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.snapshot_path = self.root / "runtime-state.json"
        self.events_path = self.root / "events.jsonl"
        self.stop_path = self.root / "STOP"
        self.approval_path = self.root / "approval.json"

    def load(self):
        if not self.snapshot_path.exists():
            return None
        with self.snapshot_path.open("r", encoding="utf-8") as handle:
            state = PipelineState.from_dict(json.load(handle))
        self._migrate_non_pipeline_prebuild_checkpoint(state)
        self._migrate_standard_flash_approval(state)
        return state

    @staticmethod
    def _migrate_non_pipeline_prebuild_checkpoint(state):
        # PRE_BUILD_FINAL_CHECK was an auxiliary acceptance report, not an
        # Arthur RELEASE-FIRST phase.  Resume at the persisted frozen flow's
        # real checkpoint without inventing a new pipeline stage.
        if state.phase != "PRE_BUILD_FINAL_CHECK":
            return
        state.phase = "CHANGE_IMPACT"
        state.next_codex_prompt = (
            "Resume the frozen Arthur production flow at CHANGE_IMPACT_GATE. "
            "Treat Windows-only uci/make checks as NOT_APPLICABLE; use the "
            "existing pinned source validation on the GitHub Linux runner, "
            "then continue automatically through the next safe phase."
        )
        state.observability["change_impact_checkpoint_migration"] = {
            "from": "PRE_BUILD_FINAL_CHECK",
            "to": "CHANGE_IMPACT",
            "acceptance_contract_role": "AUXILIARY_ONLY",
            "windows_uci": "NOT_APPLICABLE",
            "windows_make": "NOT_APPLICABLE",
        }

    @staticmethod
    def _migrate_standard_flash_approval(state):
        legacy_gates = {"REAL_FLASH_WRITE_APPROVAL", "REAL_ROLLBACK_WRITE_APPROVAL"}
        legacy_gate = state.pending_human_gate if state.pending_human_gate in legacy_gates else state.phase
        if legacy_gate not in legacy_gates:
            return
        next_phase = "AUTO_ROLLBACK_SAFETY_GATE" if legacy_gate == "REAL_ROLLBACK_WRITE_APPROVAL" else "AUTO_FLASH_SAFETY_GATE"
        state.pending_human_gate = None
        state.phase = next_phase
        state.next_codex_prompt = (
            f"Resume the verified candidate at {next_phase}. Standard sysupgrade is automatic only "
            "after all candidate, identity, SSH, hash, known-good, and rollback checks pass."
        )
        state.observability["auto_sysupgrade_policy_migration"] = {
            "from": legacy_gate,
            "to": next_phase,
            "manual_standard_sysupgrade": False,
        }

    def save(self, state):
        payload = json.dumps(state.to_dict(), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        fd, temporary = tempfile.mkstemp(prefix="runtime-state.", suffix=".tmp", dir=str(self.root))
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, str(self.snapshot_path))
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def persist_result_packet(self, payload):
        atomic_json_write(self.root / "result-packet.json", payload)

    def persist_next_action_packet(self, payload):
        atomic_json_write(self.root / "next-action-packet.json", payload)

    def append_event(self, event_type, payload):
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event_type": event_type,
            "payload": payload,
        }
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def request_stop(self):
        self.stop_path.write_text("stop\n", encoding="utf-8")

    def clear_stop(self):
        try:
            self.stop_path.unlink()
        except FileNotFoundError:
            pass

    def stop_requested(self):
        return self.stop_path.exists()
