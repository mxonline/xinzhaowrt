import unittest
from enum import Enum
import asyncio
import sys
from types import SimpleNamespace
from unittest.mock import patch

from ai_orchestrator.adapters import (
    PreflightStatus,
    choose_controller_backend,
    executor_thread_options,
    _as_dict,
)


class HeadlessAdapterTests(unittest.TestCase):
    def test_controller_prefers_responses_when_api_key_exists(self):
        backend = choose_controller_backend("secret-is-present", ["gpt-5.5"])

        self.assertEqual("responses", backend.kind)
        self.assertEqual("gpt-5.6-sol", backend.model)

    def test_controller_falls_back_to_supported_codex_model(self):
        backend = choose_controller_backend(None, ["gpt-5.4", "gpt-5.6-luna"])

        self.assertEqual("codex_thread", backend.kind)
        self.assertEqual("gpt-5.6-luna", backend.model)

    def test_controller_response_schema_is_strict_at_the_top_level(self):
        from ai_orchestrator.adapters import DECISION_JSON_SCHEMA

        self.assertFalse(DECISION_JSON_SCHEMA["additionalProperties"])

    def test_controller_candidate_schema_requires_every_declared_property(self):
        from ai_orchestrator.adapters import DECISION_JSON_SCHEMA

        candidate = DECISION_JSON_SCHEMA["properties"]["metadata"]["properties"]["candidate"]
        self.assertEqual(set(candidate["properties"]), set(candidate["required"]))

    def test_controller_schema_has_no_provider_strict_object_errors(self):
        from ai_orchestrator.adapters import DECISION_JSON_SCHEMA, validate_strict_json_schema

        self.assertEqual([], validate_strict_json_schema(DECISION_JSON_SCHEMA))

    def test_strict_schema_validator_reports_missing_required_property(self):
        from copy import deepcopy
        from ai_orchestrator.adapters import DECISION_JSON_SCHEMA, validate_strict_json_schema

        schema = deepcopy(DECISION_JSON_SCHEMA)
        schema["properties"]["metadata"]["properties"]["candidate"]["required"].remove("size_bytes")

        errors = validate_strict_json_schema(schema)

        self.assertEqual(
            ["metadata.candidate: required must include every declared property; missing size_bytes"],
            errors,
        )

    def test_controller_prompt_bounds_large_executor_items(self):
        from ai_orchestrator.adapters import _controller_prompt
        from ai_orchestrator.models import CodexResult, PipelineState

        large_item = {
            "type": "command_execution",
            "id": "large-output",
            "command": "gh run view 33491477270",
            "aggregated_output": "x" * 1_100_000,
        }
        result = CodexResult("turn-large", "Run remains in progress.", items=[large_item])
        state = PipelineState(
            "request",
            "jdcloud_re-ss-01",
            "BUILD",
            "Continue BUILD.",
            last_result=result.to_dict(),
        )

        prompt = _controller_prompt(result, state)

        self.assertLessEqual(len(prompt), 1_048_576)
        self.assertIn("large-output", prompt)

    def test_no_backend_is_a_credential_required_preflight_blocker(self):
        backend = choose_controller_backend(None, [])

        self.assertEqual("none", backend.kind)
        self.assertEqual(PreflightStatus.CREDENTIAL_REQUIRED, backend.status)
        self.assertIn("credential_discovery_failed", backend.evidence)

    def test_executor_contract_requires_auto_review_and_workspace_write(self):
        options = executor_thread_options("C:/repo")

        self.assertEqual("auto_review", options["approval_mode"])
        self.assertEqual("workspace_write", options["sandbox"])
        self.assertEqual("C:/repo", options["cwd"])

    def test_sdk_probe_payload_is_json_serializable_when_models_contain_enums(self):
        class Modality(Enum):
            TEXT = "text"

        class Model:
            def model_dump(self):
                return {"input_modalities": [Modality.TEXT]}

        self.assertEqual({"input_modalities": ["text"]}, _as_dict(Model()))

    @unittest.skipUnless(sys.version_info >= (3, 10), "official SDK requires Python 3.10+")
    def test_executor_reuses_thread_created_by_prepare_in_same_process(self):
        from ai_orchestrator import adapters
        from ai_orchestrator.models import PipelineState

        class FailingResumeCodex:
            async def thread_resume(self, *args, **kwargs):
                raise AssertionError("same-process prepare must not resume again")

        module = SimpleNamespace(
            ApprovalMode=SimpleNamespace(auto_review="auto_review"),
            Sandbox=SimpleNamespace(workspace_write="workspace_write"),
        )
        original = adapters._import_sdk
        adapters._import_sdk = lambda: module
        try:
            executor = adapters.AsyncCodexExecutor("C:/repo")
            executor.codex = FailingResumeCodex()
            executor.thread = object()
            state = PipelineState("request", "jdcloud_re-ss-01", "FORENSICS", "inspect", executor_thread_id="thread-1")
            asyncio.run(executor.prepare(state))
        finally:
            adapters._import_sdk = original

    def test_controller_recreates_thread_when_rollout_disappears_during_review(self):
        from ai_orchestrator import adapters
        from ai_orchestrator.models import CodexResult, PipelineState

        class DeadThread:
            id = "controller-dead"

            async def run(self, *args, **kwargs):
                raise RuntimeError("JSON-RPC error -32600: no rollout found for thread id controller-dead")

        class LiveThread:
            id = "controller-live"

            async def run(self, *args, **kwargs):
                return SimpleNamespace(
                    final_response='{"action":"SAFE_AUTO","reason_code":"FORENSICS_COMPLETE",'
                    '"summary":"Forensics complete.","next_codex_prompt":"Continue.",'
                    '"evidence":["evidence/forensics.json"]}',
                    items=[],
                )

        class FakeCodex:
            def __init__(self):
                self.starts = 0

            async def thread_start(self, **kwargs):
                self.starts += 1
                return DeadThread() if self.starts == 1 else LiveThread()

        module = SimpleNamespace(
            ApprovalMode=SimpleNamespace(auto_review="auto_review"),
            Sandbox=SimpleNamespace(read_only="read_only"),
        )
        original = adapters._import_sdk
        adapters._import_sdk = lambda: module
        try:
            controller = adapters.CodexThreadController("C:/repo", "gpt-5.6-sol")
            controller.codex = FakeCodex()
            state = PipelineState("request", "jdcloud_re-ss-01", "FORENSICS", "inspect")

            decision = asyncio.run(controller.review(CodexResult("turn-1", "done"), state))

            self.assertEqual("SAFE_AUTO", decision["action"])
            self.assertEqual("controller-live", state.controller_thread_id)
            self.assertEqual(2, controller.codex.starts)
        finally:
            adapters._import_sdk = original

    def test_controller_reset_terminates_hidden_process_tree_before_close(self):
        from ai_orchestrator import adapters

        class Process:
            pid = 12345

            def poll(self):
                return None

        class Codex:
            def __init__(self):
                self._client = SimpleNamespace(_sync=SimpleNamespace(_proc=Process()))
                self.closed = False

            async def close(self):
                self.closed = True

        controller = adapters.CodexThreadController("C:/repo", "gpt-5.6-sol")
        codex = Codex()
        controller.codex = codex

        with patch("ai_orchestrator.adapters.terminate_process_tree") as terminate:
            asyncio.run(controller.reset_after_error())

        terminate.assert_called_once_with(12345)
        self.assertTrue(codex.closed)
        self.assertIsNone(controller.codex)
        self.assertIsNone(controller.thread)

    def test_executor_recreates_thread_when_rollout_disappears_during_run(self):
        from ai_orchestrator import adapters
        from ai_orchestrator.models import PipelineState

        class DeadThread:
            id = "executor-dead"

            async def run(self, *args, **kwargs):
                raise RuntimeError("JSON-RPC error -32600: no rollout found for thread id executor-dead")

        class LiveThread:
            id = "executor-live"

            async def run(self, *args, **kwargs):
                return SimpleNamespace(id="turn-1", final_response="done", status="completed", items=[])

        class FakeCodex:
            def __init__(self):
                self.starts = 0

            async def thread_start(self, **kwargs):
                self.starts += 1
                return DeadThread() if self.starts == 1 else LiveThread()

        module = SimpleNamespace(
            ApprovalMode=SimpleNamespace(auto_review="auto_review"),
            Sandbox=SimpleNamespace(workspace_write="workspace_write"),
        )
        original = adapters._import_sdk
        adapters._import_sdk = lambda: module
        try:
            executor = adapters.AsyncCodexExecutor("C:/repo")
            executor.codex = FakeCodex()
            state = PipelineState("request", "jdcloud_re-ss-01", "FORENSICS", "inspect")

            result = asyncio.run(executor.run("inspect", state))

            self.assertEqual("done", result.final_response)
            self.assertEqual("executor-live", state.executor_thread_id)
            self.assertEqual(2, executor.codex.starts)
        finally:
            adapters._import_sdk = original


if __name__ == "__main__":
    unittest.main()
