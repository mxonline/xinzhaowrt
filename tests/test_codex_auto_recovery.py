import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ai_orchestrator import adapters, cli
from ai_orchestrator.models import PipelineState
from ai_orchestrator.recovery import (
    ExecutorLease,
    RecoveryEvidence,
    RecoverySupervisor,
)
from ai_orchestrator.state_store import StateStore


class CodexAutoRecoveryContractTests(unittest.TestCase):
    def make_state(self):
        return PipelineState(
            request_id="legacy-request-id",
            release_task_id="arthur-release-33813232041",
            repo="mxonline/xinzhaowrt",
            branch="main",
            source_sha="e351730066f6997ded334df5cb2dab4d8c167b29",
            device="jdcloud_re-ss-01",
            phase="CANDIDATE_WAIT",
            current_stage="CANDIDATE_WAIT",
            last_verified_stage="CHANGE_IMPACT",
            active_run_id=33813232041,
            candidate_sha256="c5522343333a6cb1449c8637718bb0aee4a33feed197fea34d3cec48aef1bc63",
            next_action="WATCH_EXISTING_RUN",
            next_codex_prompt="continue",
            executor_thread_id="diagnostic-thread-only",
            responses_conversation_id="diagnostic-session-only",
        )

    def test_task_identity_survives_response_loss_and_thread_change(self):
        state = self.make_state()
        supervisor = RecoverySupervisor(state)
        lease = ExecutorLease.acquire("executor-old")
        supervisor.attach_lease(lease)

        recovered = supervisor.handle_transport_loss(
            "HTTP 404 response lost",
            RecoveryEvidence(
                expected_fingerprint="arthur-build-v1:abc",
                candidate_fingerprint="arthur-build-v1:abc",
                candidate_run_id=33813232041,
                candidate_status="in_progress",
                candidate_conclusion="",
            ),
        )

        self.assertEqual("LOST", lease.status)
        self.assertEqual("arthur-release-33813232041", recovered.release_task_id)
        self.assertEqual("WATCH_EXISTING_RUN", recovered.next_action)
        self.assertEqual(33813232041, recovered.active_run_id)
        self.assertNotEqual("diagnostic-thread-only", recovered.release_task_id)
        self.assertNotEqual("diagnostic-session-only", recovered.release_task_id)

    def test_successful_same_fingerprint_candidate_reuses_artifact(self):
        state = self.make_state()
        supervisor = RecoverySupervisor(state)
        recovered = supervisor.reconcile(
            RecoveryEvidence(
                candidate_fingerprint="arthur-build-v1:abc",
                expected_fingerprint="arthur-build-v1:abc",
                candidate_run_id=33813232041,
                candidate_status="completed",
                candidate_conclusion="success",
                candidate_sha256=state.candidate_sha256,
            )
        )
        self.assertEqual("REUSE_ARTIFACT", recovered.next_action)
        self.assertEqual(state.candidate_sha256, recovered.candidate_sha256)

    def test_failed_same_fingerprint_candidate_routes_to_auto_repair(self):
        state = self.make_state()
        supervisor = RecoverySupervisor(state)
        recovered = supervisor.reconcile(
            RecoveryEvidence(
                candidate_fingerprint="arthur-build-v1:abc",
                expected_fingerprint="arthur-build-v1:abc",
                candidate_run_id=33969443771,
                candidate_status="completed",
                candidate_conclusion="failure",
            )
        )
        self.assertEqual("AUTO_REPAIR_FAILED_CANDIDATE", recovered.next_action)
        self.assertEqual("CANDIDATE_REPAIR", recovered.current_stage)
        self.assertEqual(33969443771, recovered.active_run_id)
        decision = recovered.observability.get("recovery_decision") or {}
        self.assertEqual("AUTO_REPAIR_FAILED_CANDIDATE", decision.get("action"))
        self.assertEqual("failure", decision.get("conclusion"))

    def test_unknown_sysupgrade_state_forces_real_device_reconcile(self):
        state = self.make_state()
        state.current_stage = "SYSUPGRADE"
        state.last_verified_stage = "AUTO_FLASH_SAFETY_GATE"
        state.next_action = "SYSUPGRADE"
        supervisor = RecoverySupervisor(state)
        recovered = supervisor.reconcile(
            RecoveryEvidence(
                sysupgrade_state="unknown",
                device_evidence_status="unknown",
            )
        )
        self.assertEqual("REAL_DEVICE_RECONCILE", recovered.next_action)
        self.assertNotEqual("SYSUPGRADE", recovered.next_action)

    def test_lease_heartbeat_and_replacement_executor(self):
        state = self.make_state()
        supervisor = RecoverySupervisor(state)
        old = ExecutorLease.acquire("executor-old")
        supervisor.attach_lease(old)
        old.heartbeat()
        supervisor.mark_executor_lost("transport disconnect")
        new = supervisor.acquire_executor("executor-new")
        self.assertEqual("LOST", old.status)
        self.assertEqual("ACTIVE", new.status)
        self.assertEqual("executor-new", new.executor_id)
        self.assertEqual(state.release_task_id, supervisor.state.release_task_id)

    def test_handoff_collects_github_artifact_device_evidence(self):
        state = self.make_state()
        state.observability.update({
            "build_dedup": {
                "expected_fingerprint": "arthur-build-v1:abc",
                "candidate_fingerprint": "arthur-build-v1:abc",
            },
            "github_actions": {
                "run_id": 33813232041,
                "status": "completed",
                "conclusion": "success",
            },
            "artifact": {
                "sha256": state.candidate_sha256,
                "build_fingerprint": "arthur-build-v1:abc",
            },
            "device": {
                "status": "verified",
                "sysupgrade_state": "completed",
            },
        })
        evidence = RecoveryEvidence.from_handoff(state)
        self.assertEqual("arthur-build-v1:abc", evidence.expected_fingerprint)
        self.assertEqual("arthur-build-v1:abc", evidence.candidate_fingerprint)
        self.assertEqual(33813232041, evidence.candidate_run_id)
        self.assertEqual("success", evidence.candidate_conclusion)
        self.assertEqual(state.candidate_sha256, evidence.candidate_sha256)
        self.assertEqual("verified", evidence.device_evidence_status)

    def test_persistence_contains_durable_release_fields(self):
        state = self.make_state()
        with tempfile.TemporaryDirectory() as tmp:
            store = StateStore(Path(tmp))
            store.save(state)
            raw = json.loads((Path(tmp) / "runtime-state.json").read_text(encoding="utf-8"))
            for key in (
                "release_task_id",
                "repo",
                "branch",
                "source_sha",
                "current_stage",
                "last_verified_stage",
                "active_run_id",
                "candidate_sha256",
                "next_action",
            ):
                self.assertIn(key, raw)
            loaded = store.load()
            self.assertEqual(state.release_task_id, loaded.release_task_id)
            self.assertEqual(state.active_run_id, loaded.active_run_id)

    def test_production_startup_shim_uses_recovery_supervisor(self):
        root = Path(__file__).resolve().parents[1]
        shim = (root / "scripts" / "run-supervisor.py").read_text(encoding="utf-8")
        self.assertIn("ai_orchestrator.recovery_runtime", shim)


class _FakeCodex:
    def __init__(self):
        self.models_called = 0

    async def account(self):
        return {"type": "chatgpt"}

    async def models(self):
        self.models_called += 1
        raise AssertionError("models() must not be called on the headless production path")


class CodexModelCacheBypassContractTests(unittest.TestCase):
    def test_executor_preflight_can_skip_remote_model_catalog(self):
        fake = _FakeCodex()
        module = SimpleNamespace()
        executor = adapters.AsyncCodexExecutor(
            Path.cwd(),
            model="gpt-5.6-terra",
            codex_factory=lambda _module: fake,
        )
        with patch.object(adapters, "_import_sdk", return_value=module):
            probe = asyncio.run(executor.preflight(include_models=False))

        self.assertTrue(probe["model_catalog_skipped"])
        self.assertEqual("gpt-5.6-terra", probe["executor_model"])
        self.assertEqual(0, fake.models_called)

    def test_build_runtime_has_explicit_chatgpt_model_without_models_list(self):
        executor_fake = _FakeCodex()
        controller_fake = _FakeCodex()
        module = SimpleNamespace()

        executor = adapters.AsyncCodexExecutor(
            Path.cwd(),
            codex_factory=lambda _module: executor_fake,
        )
        self.assertEqual("gpt-5.6-terra", executor.model)

        with patch.object(adapters, "_import_sdk", return_value=module):
            executor_probe = asyncio.run(executor.preflight())

        model_ids = cli._model_ids(executor_probe["models"])
        self.assertEqual(["gpt-5.6-terra"], model_ids)
        selection = adapters.choose_controller_backend(None, model_ids)
        self.assertEqual("codex_thread", selection.kind)
        self.assertEqual("gpt-5.6-terra", selection.model)

        controller = adapters.CodexThreadController(
            Path.cwd(),
            selection.model,
            codex_factory=lambda _module: controller_fake,
        )
        with patch.object(adapters, "_import_sdk", return_value=module):
            controller_probe = asyncio.run(controller.preflight())

        self.assertTrue(executor_probe["model_catalog_skipped"])
        self.assertTrue(controller_probe["model_catalog_skipped"])
        self.assertEqual("gpt-5.6-terra", controller_probe["controller_model"])
        self.assertEqual(0, executor_fake.models_called)
        self.assertEqual(0, controller_fake.models_called)


if __name__ == "__main__":
    unittest.main()
