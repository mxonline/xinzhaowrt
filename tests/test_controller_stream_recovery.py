import asyncio
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from ai_orchestrator.adapters import AsyncCodexExecutor, CodexThreadController, TransportAmbiguityError
from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import CodexResult, PipelineState
from ai_orchestrator.observability import runtime_status_payload
from ai_orchestrator.runtime import ProductionRuntime
from ai_orchestrator.state_store import StateStore
from ai_orchestrator.supervisor import RuntimeSupervisor
from unittest.mock import patch


def decision():
    return {
        "action": "RECOVERABLE",
        "reason_code": "TRANSPORT_RECOVERED",
        "summary": "Controller transport recovered without changing the phase.",
        "next_codex_prompt": "Continue the current checkpoint.",
        "evidence": ["runtime/controller-recovery.json"],
    }


class _Thread:
    def __init__(self, thread_id, failures=0):
        self.id = thread_id
        self.failures = failures
        self.prompts = []

    async def run(self, prompt, **kwargs):
        self.prompts.append(prompt)
        if self.failures:
            self.failures -= 1
            raise RuntimeError("stream disconnected before completion")
        return SimpleNamespace(final_response=json.dumps(decision()), items=[])


class _Codex:
    def __init__(self, started_thread, resume_error=None):
        self.started_thread = started_thread
        self.resume_error = resume_error
        self.resume_calls = 0
        self.start_calls = 0
        self.closed = False

    async def thread_start(self, **kwargs):
        self.start_calls += 1
        return self.started_thread

    async def thread_resume(self, *args, **kwargs):
        self.resume_calls += 1
        if self.resume_error:
            raise self.resume_error
        return self.started_thread

    async def close(self):
        self.closed = True


class _Executor:
    def __init__(self):
        self.thread_id = "executor-stable"

    async def run(self, prompt, state):
        state.executor_thread_id = self.thread_id
        return CodexResult("turn-1", "executor result", executor_thread_id=self.thread_id)


class _SDKModule:
    class ApprovalMode:
        auto_review = "auto_review"

    class Sandbox:
        workspace_write = "workspace_write"


class ExecutorStreamRecoveryTests(unittest.TestCase):
    def test_executor_transport_disconnect_is_ambiguous_and_not_replayed(self):
        first = _Thread("executor-original", failures=1)
        replacement = _Thread("executor-recreated")
        original_codex = _Codex(first, RuntimeError("stream disconnected before completion"))
        replacement_codex = _Codex(replacement)
        sleeps = []

        async def sleep_for(delay):
            sleeps.append(delay)

        executor = AsyncCodexExecutor(
            "C:/repo",
            model="gpt-5.6-sol",
            codex_factory=lambda _module: replacement_codex,
            sleep_fn=sleep_for,
            backoff_base=1.0,
            backoff_max=2.0,
        )
        executor.codex = original_codex
        executor.thread = first
        state = PipelineState("request", "jdcloud_re-ss-01", "BUILD", "same prompt", executor_thread_id="executor-original")

        with self.assertRaises(TransportAmbiguityError):
            asyncio.run(executor.run("same prompt", state))

        self.assertEqual("executor-original", state.executor_thread_id)
        self.assertEqual(0, original_codex.resume_calls)
        self.assertEqual(0, replacement_codex.start_calls)
        self.assertEqual([], sleeps)
        self.assertEqual(["same prompt"], first.prompts)
        self.assertEqual([], replacement.prompts)

    def test_runtime_blocks_after_ambiguous_executor_disconnect_without_controller_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))

            class AmbiguousExecutor:
                last_recovery = None

                async def run(self, prompt, state):
                    raise TransportAmbiguityError("executor request outcome is ambiguous")

            class UnexpectedController:
                async def review(self, result, state):
                    raise AssertionError("controller must not review an ambiguous executor result")

            runtime = ProductionRuntime(store, AmbiguousExecutor(), UnexpectedController(), ArthurPipeline())
            store.save(PipelineState("request", "jdcloud_re-ss-01", "FLASH", "flash the candidate"))

            final = asyncio.run(runtime.run(max_turns=1))

            self.assertEqual("SAFETY_BLOCKED", final.terminal_state)
            self.assertEqual("FLASH", final.phase)
            self.assertEqual("blocked", final.last_result["status"])
            self.assertIn("runtime/executor-transport-ambiguous.log", final.last_result["evidence"])
            self.assertEqual("EXECUTOR_TRANSPORT_AMBIGUOUS", final.last_decision["reason_code"])


class ControllerStreamRecoveryTests(unittest.TestCase):
    def test_controller_replays_same_result_after_resume_failure_and_recreates_thread(self):
        first = _Thread("controller-original", failures=1)
        replacement = _Thread("controller-recreated")
        original_codex = _Codex(first, RuntimeError("stream disconnected before completion"))
        replacement_codex = _Codex(replacement)
        sleeps = []

        def factory(_module):
            return replacement_codex

        async def sleep_for(delay):
            sleeps.append(delay)

        controller = CodexThreadController(
            "C:/repo",
            "gpt-5.6-sol",
            codex_factory=factory,
            sleep_fn=sleep_for,
            backoff_base=1.0,
            backoff_max=2.0,
        )
        controller.codex = original_codex
        controller.thread = first
        state = PipelineState("request", "jdcloud_re-ss-01", "BUILD", "Continue", controller_thread_id="controller-original")
        result = CodexResult("turn-1", "same durable result", evidence=["result-packet.json"])

        recovered = asyncio.run(controller.review(result, state))

        self.assertEqual("RECOVERABLE", recovered["action"])
        self.assertEqual("controller-recreated", state.controller_thread_id)
        self.assertEqual(1, original_codex.resume_calls)
        self.assertEqual(1, replacement_codex.start_calls)
        self.assertEqual([1.0], sleeps)
        self.assertEqual(1, len(first.prompts))
        self.assertEqual(1, len(replacement.prompts))
        self.assertIn("same durable result", replacement.prompts[0])

    def test_runtime_persists_packets_and_keeps_checkpoint_on_controller_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            first = _Thread("controller-original", failures=1)
            replacement = _Thread("controller-recreated")
            original_codex = _Codex(first, RuntimeError("stream disconnected before completion"))
            replacement_codex = _Codex(replacement)
            def factory(_module):
                return replacement_codex

            async def no_wait(_delay):
                return None

            controller = CodexThreadController(
                "C:/repo",
                "gpt-5.6-sol",
                codex_factory=factory,
                sleep_fn=no_wait,
                backoff_base=0.0,
                backoff_max=0.0,
            )
            controller.codex = original_codex
            executor = _Executor()
            runtime = ProductionRuntime(store, executor, controller, ArthurPipeline())
            initial = PipelineState(
                "request",
                "jdcloud_re-ss-01",
                "BUILD",
                "Continue",
                executor_thread_id="executor-stable",
                candidate={"id": "candidate-stable", "sha256": "sha-stable"},
                known_good={"id": "known-good-stable"},
            )
            store.save(initial)

            final = asyncio.run(runtime.run(max_turns=1))

            result_packet = json.loads((Path(directory) / "result-packet.json").read_text(encoding="utf-8"))
            decision_packet = json.loads((Path(directory) / "next-action-packet.json").read_text(encoding="utf-8"))
            events = [json.loads(line) for line in (Path(directory) / "events.jsonl").read_text(encoding="utf-8").splitlines()]
            event_types = [event["event_type"] for event in events]
            self.assertEqual("turn-1", result_packet["turn_id"])
            self.assertEqual("executor result", result_packet["final_response"])
            self.assertEqual("RECOVERABLE", decision_packet["action"])
            self.assertEqual("BUILD", final.phase)
            self.assertEqual("executor-stable", final.executor_thread_id)
            self.assertEqual("candidate-stable", final.candidate["id"])
            self.assertEqual("known-good-stable", final.known_good["id"])
            self.assertEqual("controller-recreated", final.controller_thread_id)
            self.assertLess(event_types.index("result_packet_persisted"), event_types.index("executor_result"))
            self.assertLess(event_types.index("next_action_packet_persisted"), event_types.index("controller_decision"))
            self.assertIn("controller_stream_recovered", event_types)

    def test_runtime_status_exposes_independent_controller_channel(self):
        state = PipelineState("request", "jdcloud_re-ss-01", "BUILD", "Continue")
        state.observability = {
            "runtime": "LIVE",
            "stage": "BUILD",
            "heartbeat_at": "2026-09-02T00:00:00+00:00",
            "active_process": {"pid": 11, "alive": True},
            "executor_process": {"pid": 11, "alive": True},
            "controller_process": {"pid": 22, "alive": False},
        }

        payload = runtime_status_payload(state)

        self.assertEqual({"pid": 11, "alive": True}, payload["executor_process"])
        self.assertEqual({"pid": 22, "alive": False}, payload["controller_process"])
        self.assertIsNone(payload["controller_thread_id"])

    def test_supervisor_does_not_restart_runtime_for_controller_only_degradation(self):
        supervisor = RuntimeSupervisor("C:/state", project_root="C:/repo")
        now = datetime.now(timezone.utc).isoformat()
        status = {
            "runtime": "LIVE",
            "heartbeat_at": now,
            "last_progress_at": now,
            "daemon_pid": 10,
            "executor_process": {"pid": 11, "alive": True},
            "controller_process": {"pid": 22, "alive": False},
        }
        state = {"observability": {}}
        with patch("ai_orchestrator.supervisor.process_is_alive", return_value=True):
            health = supervisor._runtime_healthy(status, state, {})

        self.assertTrue(health["healthy"])
        self.assertTrue(health["controller_degraded"])

    def test_stream_disconnect_is_not_classified_as_usage_limit(self):
        from ai_orchestrator.runtime import _controller_failure_reason

        self.assertEqual(
            "CONTROLLER_TRANSPORT_RECOVERABLE",
            _controller_failure_reason("RuntimeError: stream disconnected before completion"),
        )
        self.assertEqual(
            "CONTROLLER_USAGE_LIMIT",
            _controller_failure_reason("AdapterError: insufficient_quota"),
        )


if __name__ == "__main__":
    unittest.main()
