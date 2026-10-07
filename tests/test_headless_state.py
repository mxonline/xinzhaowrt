import json
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.models import PipelineState
from ai_orchestrator.state_store import StateStore


class HeadlessStateTests(unittest.TestCase):
    def test_snapshot_survives_atomic_replace_and_event_is_replayable(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = PipelineState("request-1", "jdcloud_re-ss-01", "FORENSICS", "Inspect the source tree.")

            store.save(state)
            store.append_event("executor_result", {"turn_id": "turn-1"})

            loaded = store.load()
            events = [json.loads(line) for line in store.events_path.read_text(encoding="utf-8").splitlines()]

            self.assertEqual("FORENSICS", loaded.phase)
            self.assertEqual("executor_result", events[0]["event_type"])
            self.assertEqual("turn-1", events[0]["payload"]["turn_id"])

    def test_stop_marker_is_separate_from_terminal_state(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            self.assertFalse(store.stop_requested())

    def test_legacy_standard_flash_approval_is_migrated_to_auto_safety_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = PipelineState(
                "request-legacy",
                "jdcloud_re-ss-01",
                "REAL_FLASH_WRITE_APPROVAL",
                None,
                pending_human_gate="REAL_FLASH_WRITE_APPROVAL",
            )
            store.save(state)

            loaded = store.load()

            self.assertEqual("AUTO_FLASH_SAFETY_GATE", loaded.phase)
            self.assertIsNone(loaded.pending_human_gate)
            self.assertIn("auto_sysupgrade_policy_migration", loaded.observability)
            store.request_stop()
            self.assertTrue(store.stop_requested())
            store.clear_stop()
            self.assertFalse(store.stop_requested())

    def test_non_pipeline_prebuild_checkpoint_is_migrated_to_change_impact(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            state = PipelineState(
                "request-prebuild",
                "jdcloud_re-ss-01",
                "PRE_BUILD_FINAL_CHECK",
                "Recover the pre-build final check.",
            )
            state.observability.update({"runtime": "STOPPED", "next_action": "RECOVERABLE_PREFLIGHT_TOOLING_OR_LINUX_PREFLIGHT"})
            store.save(state)

            loaded = store.load()

            self.assertEqual("CHANGE_IMPACT", loaded.phase)
            self.assertIn("change_impact_checkpoint_migration", loaded.observability)
            self.assertIn("CHANGE_IMPACT", loaded.next_codex_prompt)


if __name__ == "__main__":
    unittest.main()
