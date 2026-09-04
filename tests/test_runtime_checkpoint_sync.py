import unittest
from pathlib import Path

from ai_orchestrator.models import ActionKind, GPTDecision, HumanGate, PipelineState
from ai_orchestrator.policy import PolicyOutcome, PolicyRoute
from ai_orchestrator.runtime import ProductionRuntime


class _Store:
    def __init__(self):
        self.events = []
        self.root = Path(".")

    def append_event(self, name, payload):
        self.events.append((name, payload))


class _Pipeline:
    def next_phase(self, phase, action):
        self.assertion = (phase, action)
        return "ADH_CHINESE"


class RuntimeCheckpointSyncTests(unittest.TestCase):
    def test_safe_auto_phase_change_updates_durable_checkpoint_fields(self):
        store = _Store()
        runtime = ProductionRuntime(store, None, None, _Pipeline())
        state = PipelineState(
            request_id="arthur-adh-quickstart",
            device="jdcloud_re-ss-01",
            phase="ADH_MANAGEMENT",
            current_stage="ADH_MANAGEMENT",
            next_action="ADH_MANAGEMENT",
            next_codex_prompt="continue ADH",
        )
        decision = GPTDecision(
            action=ActionKind.SAFE_AUTO,
            reason_code="ADH_MANAGEMENT_VERIFIED",
            summary="advance",
            next_codex_prompt="continue Chinese localization",
            metadata={"next_phase": "ADH_CHINESE"},
        )
        runtime._apply_outcome(state, PolicyOutcome(PolicyRoute.SAFE_AUTO, decision))

        self.assertEqual(state.phase, "ADH_CHINESE")
        self.assertEqual(state.current_stage, "ADH_CHINESE")
        self.assertEqual(state.next_action, "ADH_CHINESE")
        self.assertEqual(state.next_codex_prompt, "continue Chinese localization")

    def test_human_gate_keeps_canonical_phase_as_next_action(self):
        store = _Store()
        runtime = ProductionRuntime(store, None, None, _Pipeline())
        state = PipelineState(
            request_id="arthur-adh-quickstart",
            device="jdcloud_re-ss-01",
            phase="AUTO_FLASH_SAFETY_GATE",
            current_stage="AUTO_FLASH_SAFETY_GATE",
            next_action="AUTO_FLASH_SAFETY_GATE",
            next_codex_prompt="verify flash safety",
        )
        decision = GPTDecision(
            action=ActionKind.HUMAN_GATE,
            reason_code="NO_SAFE_ROLLBACK",
            summary="human safety gate",
            human_gate=HumanGate.NO_SAFE_ROLLBACK,
        )
        runtime._apply_outcome(
            state,
            PolicyOutcome(PolicyRoute.HUMAN_GATE, decision, HumanGate.NO_SAFE_ROLLBACK),
        )

        self.assertEqual(state.phase, "AUTO_FLASH_SAFETY_GATE")
        self.assertEqual(state.current_stage, "AUTO_FLASH_SAFETY_GATE")
        self.assertEqual(state.next_action, "AUTO_FLASH_SAFETY_GATE")
        self.assertEqual(state.pending_human_gate, "NO_SAFE_ROLLBACK")
        self.assertIsNone(state.next_codex_prompt)


if __name__ == "__main__":
    unittest.main()
