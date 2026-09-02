import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import ActionKind, CodexResult, GPTDecision, PipelineState
from ai_orchestrator.policy import policy_gate
from ai_orchestrator.runtime import ProductionRuntime


class _Store:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="xinzhao-prebuild-gate-"))
        self.events = []

    def append_event(self, name, payload):
        self.events.append((name, payload))


class PrebuildPolicyGateTests(unittest.TestCase):
    def setUp(self):
        self.pipeline = ArthurPipeline()

    def _state(self, phase):
        return PipelineState(
            request_id="arthur-production",
            device="jdcloud_re-ss-01",
            phase=phase,
            next_codex_prompt=self.pipeline.prompt_for(phase),
        )

    def _pass_result(self):
        return CodexResult(
            turn_id="live-pass-1",
            final_response="\n".join(
                [
                    "V013_LIVE_BASELINE=PASS version=0.1.3 build_id=33462873812",
                    "ADGUARD_LIVE=PASS final_state=stopped_disabled",
                    "QUICKSTART_LIVE=PASS homepage=admin/quickstart",
                    "WIFI_LIVE=PASS ssid=xinzhaowrt key=REDACTED",
                    "V013_PREBUILD_REAL_DEVICE_FEATURES=PASS",
                ]
            ),
            evidence=["output/real-device/v013-prebuild-live.log"],
        )

    def test_prebuild_phase_is_before_fast_gate_and_build(self):
        phases = self.pipeline.phases
        prebuild = phases.index("PREBUILD_REAL_DEVICE_FEATURES")
        self.assertLess(prebuild, phases.index("FAST_GATE"))
        self.assertLess(prebuild, phases.index("BUILD"))

    def test_missing_prebuild_pass_rewinds_legacy_build_state(self):
        state = self._state("BUILD")
        event = self.pipeline.enforce_pre_execution_gate(state)
        self.assertIsNotNone(event)
        self.assertEqual("PREBUILD_REAL_DEVICE_FEATURES", state.phase)
        self.assertEqual("PREBUILD_REAL_DEVICE_FEATURES_REQUIRED", event["reason_code"])

    def test_controller_cannot_jump_to_build_before_prebuild_pass(self):
        store = _Store()
        state = self._state("PREBUILD_REAL_DEVICE_FEATURES")
        runtime = ProductionRuntime(store, None, None, self.pipeline)
        decision = GPTDecision(
            action=ActionKind.SAFE_AUTO,
            reason_code="CONTROLLER_WANTS_BUILD",
            summary="attempt build",
            next_codex_prompt="build now",
            metadata={"next_phase": "BUILD"},
        )
        runtime._apply_outcome(state, policy_gate(decision))
        self.assertEqual("PREBUILD_REAL_DEVICE_FEATURES", state.phase)
        self.assertIn("PREBUILD_REAL_DEVICE_FEATURES", state.next_codex_prompt)

    def test_pass_requires_all_real_device_markers_and_then_forces_fast_gate_first(self):
        state = self._state("PREBUILD_REAL_DEVICE_FEATURES")
        incomplete = CodexResult(
            turn_id="fake-pass",
            final_response="V013_PREBUILD_REAL_DEVICE_FEATURES=PASS",
            evidence=[],
        )
        self.assertIsNone(self.pipeline.record_result(state, incomplete))
        self.assertFalse(self.pipeline.prebuild_gate_passed(state))

        recorded = self.pipeline.record_result(state, self._pass_result())
        self.assertIsNotNone(recorded)
        self.assertTrue(self.pipeline.prebuild_gate_passed(state))

        store = _Store()
        runtime = ProductionRuntime(store, None, None, self.pipeline)
        decision = GPTDecision(
            action=ActionKind.SAFE_AUTO,
            reason_code="PASS_AND_BUILD",
            summary="try to skip fast gate",
            next_codex_prompt="build now",
            metadata={"next_phase": "BUILD"},
        )
        runtime._apply_outcome(state, policy_gate(decision))
        self.assertEqual("FAST_GATE", state.phase)

        decision2 = GPTDecision(
            action=ActionKind.SAFE_AUTO,
            reason_code="FAST_GATE_PASS",
            summary="advance to build",
            next_codex_prompt="run build",
            metadata={"next_phase": "BUILD"},
        )
        runtime._apply_outcome(state, policy_gate(decision2))
        self.assertEqual("BUILD", state.phase)


if __name__ == "__main__":
    unittest.main()
