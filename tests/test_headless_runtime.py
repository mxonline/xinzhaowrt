import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import CodexResult
from ai_orchestrator.runtime import ProductionRuntime
from ai_orchestrator.state_store import StateStore


class RecordingExecutor:
    def __init__(self):
        self.prompts = []

    async def run(self, prompt, state):
        self.prompts.append(prompt)
        return CodexResult("turn-%d" % len(self.prompts), "executor completed %s" % state.phase, executor_thread_id="executor-1")


class ThreeTurnController:
    def __init__(self):
        self.results = []

    async def review(self, result, state):
        self.results.append(result)
        if len(self.results) == 1:
            return {
                "action": "SAFE_AUTO",
                "reason_code": "FORENSICS_COMPLETE",
                "summary": "Forensics evidence is complete.",
                "next_codex_prompt": "Perform change impact analysis.",
                "evidence": ["evidence/forensics.json"],
            }
        if len(self.results) == 2:
            return {
                "action": "RECOVERABLE",
                "reason_code": "BUILD_ERROR",
                "summary": "Retry the current phase after automatic recovery.",
                "next_codex_prompt": "Repair the build failure and rerun the current phase.",
                "evidence": ["output/logs/build.log"],
            }
        return {
            "action": "TERMINAL",
            "reason_code": "RELEASE_VERIFIED",
            "summary": "All production evidence is verified.",
            "terminal_state": "PRODUCTION_RELEASED",
            "evidence": ["release/manifest.json"],
        }


class HeadlessRuntimeTests(unittest.TestCase):
    def test_three_turn_chain_is_persisted_and_automatically_continues(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            executor = RecordingExecutor()
            controller = ThreeTurnController()
            runtime = ProductionRuntime(store, executor, controller, ArthurPipeline())

            state = asyncio.run(runtime.run(request_id="live-test", max_turns=3))
            events = [json.loads(line) for line in store.events_path.read_text(encoding="utf-8").splitlines()]
            event_types = [event["event_type"] for event in events]

            self.assertEqual("PRODUCTION_RELEASED", state.terminal_state)
            self.assertEqual(3, state.turn_count)
            self.assertEqual(3, len(executor.prompts))
            self.assertIn("executor_result", event_types)
            self.assertIn("controller_decision", event_types)
            automatic = [event for event in events if event["event_type"] == "next_turn"]
            self.assertTrue(all(event["payload"]["source"] == "executor" for event in events if event["event_type"] == "executor_result"))
            self.assertTrue(all(event["payload"]["reviewed_by"] == "controller" for event in events if event["event_type"] == "controller_decision"))
            self.assertTrue(all(event["payload"]["next_action_generated_by"] == "controller" for event in automatic))
            self.assertTrue(all(event["payload"]["next_turn_started_automatically"] for event in automatic))

    def test_verified_standard_sysupgrade_advances_without_human_gate(self):
        class GateController:
            async def review(self, result, state):
                from tests.test_auto_sysupgrade_policy import auto_flash_decision

                return auto_flash_decision()

        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = asyncio.run(
                ProductionRuntime(store, RecordingExecutor(), GateController(), ArthurPipeline()).run(
                    request_id="gate-test", max_turns=1
                )
            )

            self.assertEqual("FLASH", state.phase)
            self.assertIsNone(state.pending_human_gate)
            self.assertIsNone(state.terminal_state)

    def test_preflight_report_can_be_persisted_without_ui_callback(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = asyncio.run(
                ProductionRuntime(
                    store,
                    RecordingExecutor(),
                    ThreeTurnController(),
                    ArthurPipeline(),
                    preflight={"status": "READY", "checks": {"source_tree": True}},
                ).run(request_id="preflight-test", max_turns=1)
            )

            self.assertEqual("READY", state.preflight["status"])

    def test_slow_executor_is_recovered_by_controller_instead_of_hanging_daemon(self):
        class HangingExecutor:
            async def run(self, prompt, state):
                await asyncio.sleep(1)

        class ReleaseController:
            async def review(self, result, state):
                self.assert_error(result)
                return {
                    "action": "TERMINAL",
                    "reason_code": "RECOVERY_COMPLETE",
                    "summary": "Timeout was captured as executor evidence.",
                    "terminal_state": "PRODUCTION_RELEASED",
                    "evidence": ["runtime/timeout.json"],
                }

            @staticmethod
            def assert_error(result):
                if result.status != "error":
                    raise AssertionError("executor timeout must be serialized as an error result")

        with tempfile.TemporaryDirectory() as directory:
            state = asyncio.run(
                ProductionRuntime(
                    StateStore(Path(directory)),
                    HangingExecutor(),
                    ReleaseController(),
                    ArthurPipeline(),
                    turn_timeout=0.01,
                ).run(request_id="timeout-test", max_turns=1)
            )

            self.assertEqual("PRODUCTION_RELEASED", state.terminal_state)

    def test_slow_thread_prepare_is_serialized_and_recovered(self):
        class HangingPrepareExecutor(RecordingExecutor):
            async def prepare(self, state):
                await asyncio.sleep(1)

        class ReleaseController:
            async def review(self, result, state):
                if result.status != "error":
                    raise AssertionError("thread preparation timeout must be serialized as an error result")
                return {
                    "action": "TERMINAL",
                    "reason_code": "PREPARE_RECOVERY_COMPLETE",
                    "summary": "Thread preparation timeout was recovered automatically.",
                    "terminal_state": "PRODUCTION_RELEASED",
                    "evidence": ["runtime/prepare-timeout.json"],
                }

        with tempfile.TemporaryDirectory() as directory:
            state = asyncio.run(
                ProductionRuntime(
                    StateStore(Path(directory)),
                    HangingPrepareExecutor(),
                    ReleaseController(),
                    ArthurPipeline(),
                    turn_timeout=0.01,
                ).run(request_id="prepare-timeout-test", max_turns=1)
            )

            self.assertEqual("PRODUCTION_RELEASED", state.terminal_state)


if __name__ == "__main__":
    unittest.main()
