import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from ai_orchestrator.models import PipelineState
from ai_orchestrator import supervisor as supervisor_module
from ai_orchestrator.supervisor import RuntimeSupervisor


class FakeProcess:
    _next_pid = 40000

    def __init__(self):
        type(self)._next_pid += 1
        self.pid = type(self)._next_pid
        self.returncode = None
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15


class SupervisorTests(unittest.TestCase):
    def make_state(self, directory, phase="FORENSICS", pending=None, terminal=None):
        state = PipelineState(
            request_id="arthur-production",
            device="arthur",
            phase=phase,
            next_codex_prompt="continue",
            pending_human_gate=pending,
            terminal_state=terminal,
        )
        state.observability.update({
            "runtime": "STOPPED",
            "heartbeat_at": "2026-08-30T00:00:00+00:00",
            "last_progress_at": "2026-08-30T00:00:00+00:00",
        })
        (Path(directory) / "runtime-state.json").write_text(
            json.dumps(state.to_dict()), encoding="utf-8"
        )

    def test_stale_stopped_runtime_launches_resume_from_persisted_state(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_state(directory)
            processes = []

            def launcher(command):
                processes.append(command)
                return FakeProcess()

            supervisor = RuntimeSupervisor(
                directory,
                launcher=launcher,
                now=lambda: time.time(),
                heartbeat_timeout=120,
            )
            result = supervisor.run_once()
            self.assertEqual("RECOVERING", result["status"])
            self.assertEqual(1, len(processes))
            self.assertIn("resume", processes[0])
            self.assertIn("--state-dir", processes[0])

    def test_human_gate_is_never_bypassed(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_state(directory, pending="UNKNOWN_DEVICE_IDENTITY")
            supervisor = RuntimeSupervisor(directory, launcher=lambda command: self.fail("launched"))
            result = supervisor.run_once()
            self.assertEqual("WAITING_HUMAN", result["status"])

    def test_flash_phase_stall_is_deferred_without_killing_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_state(directory, phase="FLASH")
            supervisor = RuntimeSupervisor(directory, launcher=lambda command: self.fail("launched"))
            result = supervisor.run_once()
            self.assertEqual("DEFERRED_SAFETY_PHASE", result["status"])

    def test_crash_loop_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_state(directory)
            supervisor = RuntimeSupervisor(
                directory,
                launcher=lambda command: (_ for _ in ()).throw(OSError("boom")),
                max_restarts=2,
                backoff_base=0,
            )
            self.assertEqual("RECOVERING", supervisor.run_once()["status"])
            self.assertEqual("RECOVERING", supervisor.run_once()["status"])
            self.assertEqual("CRASH_LOOP_BLOCKED", supervisor.run_once()["status"])

    def test_singleton_lock_rejects_second_supervisor(self):
        with tempfile.TemporaryDirectory() as directory:
            first = RuntimeSupervisor(directory)
            second = RuntimeSupervisor(directory)
            with first.locked():
                with self.assertRaises(RuntimeError):
                    with second.locked():
                        pass

    def test_startup_registration_is_idempotent_windows_entrypoint(self):
        with tempfile.TemporaryDirectory() as directory:
            completed = type("Completed", (), {"returncode": 0})()
            with patch.object(supervisor_module.os, "name", "nt"), patch.object(
                supervisor_module.subprocess, "run", return_value=completed
            ) as run:
                result = supervisor_module.ensure_windows_startup(directory, directory)
            self.assertEqual("PASS", result["status"])
            command = run.call_args.args[0]
            self.assertIn("XinZhaoWrtGPTCodexBridgeSupervisor", command)
            self.assertIn("run-supervisor.py", " ".join(command))


if __name__ == "__main__":
    unittest.main()
