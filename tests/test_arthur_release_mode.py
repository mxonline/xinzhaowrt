import unittest

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import ActionKind


class ArthurReleaseModeTests(unittest.TestCase):
    def test_release_only_routes_artifact_directly_to_release_gate(self):
        pipeline = ArthurPipeline(release_mode="RELEASE_ONLY")
        self.assertEqual(
            pipeline.next_phase("ARTIFACT", ActionKind.SAFE_AUTO),
            "RELEASE_GATE",
        )

    def test_release_only_candidate_can_release_but_never_flash(self):
        result = ArthurPipeline.classify_candidate_route(
            ArthurPipeline.production_candidate_workflow,
            ArthurPipeline.production_candidate_evidence,
            release_mode="RELEASE_ONLY",
        )
        self.assertEqual(result["route"], "PRODUCTION_CANDIDATE")
        self.assertTrue(result["release_allowed"])
        self.assertFalse(result["flash_allowed"])

    def test_unknown_release_mode_fails_closed(self):
        result = ArthurPipeline.classify_candidate_route(
            ArthurPipeline.production_candidate_workflow,
            ArthurPipeline.production_candidate_evidence,
            release_mode="UNKNOWN",
        )
        self.assertEqual(result["route"], "SAFETY_BLOCKED_UNKNOWN_RELEASE_MODE")
        self.assertFalse(result["release_allowed"])
        self.assertFalse(result["flash_allowed"])

    def test_legacy_mode_keeps_historical_flash_route_parseable(self):
        pipeline = ArthurPipeline(release_mode="FLASH_AND_VERIFY")
        self.assertEqual(
            pipeline.next_phase("ARTIFACT", ActionKind.SAFE_AUTO),
            "PRE_FLASH",
        )


if __name__ == "__main__":
    unittest.main()
