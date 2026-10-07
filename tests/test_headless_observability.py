import asyncio
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.cli import main
from ai_orchestrator.models import CodexResult
from ai_orchestrator.runtime import ProductionRuntime
from ai_orchestrator.state_store import StateStore


class SlowExecutor:
    async def run(self, prompt, state):
        await asyncio.sleep(0.06)
        return CodexResult("turn-1", "done", executor_thread_id="executor-1")


class ReleaseController:
    async def review(self, result, state):
        return {
            "action": "TERMINAL",
            "reason_code": "TEST_RELEASE",
            "summary": "test release",
            "terminal_state": "PRODUCTION_RELEASED",
            "evidence": ["test/evidence.json"],
        }


class HeadlessObservabilityTests(unittest.TestCase):
    def test_heartbeat_and_runtime_health_are_persisted(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = asyncio.run(
                ProductionRuntime(
                    store,
                    SlowExecutor(),
                    ReleaseController(),
                    ArthurPipeline(),
                    heartbeat_interval=0.01,
                    health_interval=0.02,
                    stall_timeout=10,
                    turn_timeout=1,
                ).run(request_id="observability-test", max_turns=1)
            )
            events = [json.loads(line) for line in store.events_path.read_text(encoding="utf-8").splitlines()]
            event_types = [event["event_type"] for event in events]
            self.assertEqual("PRODUCTION_RELEASED", state.terminal_state)
            self.assertIn("heartbeat", event_types)
            self.assertIn("runtime_health", event_types)
            self.assertIn("observability", state.to_dict())
            self.assertTrue(state.to_dict()["observability"]["heartbeat_at"])

    def test_status_watch_prints_operator_fields_once(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = ArthurPipeline().initial_state("watch-test")
            store.save(state)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = main(["status", "--state-dir", directory, "--watch", "--iterations", "1"])
            self.assertEqual(0, result)
            text = output.getvalue()
            for label in ("Runtime:", "PID:", "Stage:", "Action:", "Heartbeat:", "Last Progress:", "Active Process:", "Human Input Required:"):
                self.assertIn(label, text)

    def test_stall_diagnosis_is_a_watchdog_event_not_a_human_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = asyncio.run(
                ProductionRuntime(
                    store,
                    SlowExecutor(),
                    ReleaseController(),
                    ArthurPipeline(),
                    heartbeat_interval=0.01,
                    health_interval=0.02,
                    stall_timeout=0.01,
                    turn_timeout=1,
                ).run(request_id="stall-test", max_turns=1)
            )
            events = [json.loads(line) for line in store.events_path.read_text(encoding="utf-8").splitlines()]
            stall_events = [event for event in events if event["event_type"] == "STALL_DIAGNOSIS"]
            self.assertTrue(stall_events)
            self.assertIsNone(state.pending_human_gate)


if __name__ == "__main__":
    unittest.main()
