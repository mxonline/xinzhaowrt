import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from ai_orchestrator.supervisor import RuntimeSupervisor


class _FakeProcess:
    def __init__(self, pid, exit_code):
        self.pid = pid
        self._exit_code = exit_code

    def poll(self):
        return self._exit_code

    def terminate(self):
        return None


class SupervisorChildExitObservationTests(unittest.TestCase):
    def test_run_once_persists_child_exit_evidence_before_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            heartbeat = datetime.now(timezone.utc).isoformat()
            (root / "runtime-status.json").write_text(
                json.dumps({"runtime": "LIVE", "heartbeat_at": heartbeat}),
                encoding="utf-8",
            )
            (root / "runtime-state.json").write_text(
                json.dumps({"phase": "BUILD", "terminal_state": ""}),
                encoding="utf-8",
            )
            (root / "supervisor.log").write_text(
                "TransportClosedError: synthetic child failure\n",
                encoding="utf-8",
            )

            processes = iter((_FakeProcess(1234, 17), _FakeProcess(5678, None)))
            supervisor = RuntimeSupervisor(
                state_dir=root,
                project_root=root,
                launcher=lambda _command: next(processes),
                now=lambda: 1000.0,
                backoff_base=0.0,
            )

            with patch("ai_orchestrator.supervisor.process_is_alive", return_value=False):
                first = supervisor.run_once()
                second = supervisor.run_once()

            persisted = json.loads((root / "supervisor-state.json").read_text(encoding="utf-8"))
            status = json.loads((root / "supervisor-status.json").read_text(encoding="utf-8"))

            self.assertEqual("RECOVERING", first["status"])
            self.assertEqual("RECOVERING", second["status"])
            self.assertEqual(1234, persisted["last_child_pid"])
            self.assertEqual(17, persisted["last_child_exit_code"])
            self.assertTrue(persisted["last_child_exit_at"])
            self.assertIn("TransportClosedError", persisted["last_child_error_tail"])
            self.assertEqual(persisted["last_child_pid"], status["last_child_pid"])
            self.assertEqual(persisted["last_child_exit_code"], status["last_child_exit_code"])
            self.assertIn("ai_orchestrator", " ".join(persisted["last_child_command"]))
            self.assertTrue(persisted["last_child_start_at"])

    def test_stale_waiting_human_runtime_is_restarted_after_gate_cleared(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            heartbeat = datetime.now(timezone.utc).isoformat()
            (root / "runtime-status.json").write_text(
                json.dumps({"runtime": "WAITING_HUMAN", "heartbeat_at": heartbeat, "daemon_pid": 1234}),
                encoding="utf-8",
            )
            (root / "runtime-state.json").write_text(
                json.dumps({
                    "phase": "CHANGE_IMPACT",
                    "pending_human_gate": None,
                    "terminal_state": "",
                }),
                encoding="utf-8",
            )
            (root / "supervisor-state.json").write_text(
                json.dumps({"child_pid": 1234, "restart_times": [], "restart_count": 0, "next_retry_at": 0}),
                encoding="utf-8",
            )

            launched = []
            supervisor = RuntimeSupervisor(
                state_dir=root,
                project_root=root,
                launcher=lambda command: launched.append(command) or _FakeProcess(5678, None),
                now=lambda: 1000.0,
                backoff_base=0.0,
            )

            with patch("ai_orchestrator.supervisor.process_is_alive", return_value=True), patch.object(
                supervisor, "_terminate_pid"
            ) as terminate:
                status = supervisor.run_once()

            self.assertEqual("RECOVERING", status["status"])
            self.assertTrue(status["stale_human_wait"])
            terminate.assert_called_once_with(1234)
            self.assertEqual(1, len(launched))
            persisted = json.loads((root / "supervisor-state.json").read_text(encoding="utf-8"))
            self.assertEqual(5678, persisted["child_pid"])

    def test_real_human_gate_remains_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            heartbeat = datetime.now(timezone.utc).isoformat()
            (root / "runtime-status.json").write_text(
                json.dumps({"runtime": "WAITING_HUMAN", "heartbeat_at": heartbeat}),
                encoding="utf-8",
            )
            (root / "runtime-state.json").write_text(
                json.dumps({
                    "phase": "CHANGE_IMPACT",
                    "pending_human_gate": "NEW_CREDENTIAL_PROVISIONING",
                    "terminal_state": "",
                }),
                encoding="utf-8",
            )

            launched = []
            supervisor = RuntimeSupervisor(
                state_dir=root,
                project_root=root,
                launcher=lambda command: launched.append(command) or _FakeProcess(5678, None),
                now=lambda: 1000.0,
                backoff_base=0.0,
            )

            status = supervisor.run_once()

            self.assertEqual("WAITING_HUMAN", status["status"])
            self.assertEqual("no_bypass", status["action"])
            self.assertEqual([], launched)


if __name__ == "__main__":
    unittest.main()
