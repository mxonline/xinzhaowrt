import unittest

from ai_orchestrator.arthur import ArthurPipeline


class ArthurPipelineTests(unittest.TestCase):
    def test_handoff_starts_with_forensics_and_contains_required_production_phases(self):
        pipeline = ArthurPipeline()

        self.assertEqual("FORENSICS", pipeline.phases[0])
        self.assertLess(pipeline.phases.index("ARGON_KUCAT"), pipeline.phases.index("BUILD"))
        self.assertLess(pipeline.phases.index("PRE_FLASH"), pipeline.phases.index("AUTO_FLASH_SAFETY_GATE"))
        self.assertLess(pipeline.phases.index("AUTO_FLASH_SAFETY_GATE"), pipeline.phases.index("FLASH"))
        self.assertEqual("PRODUCTION_RELEASED", pipeline.phases[-1])

    def test_recovery_keeps_current_phase_and_safe_auto_advances(self):
        pipeline = ArthurPipeline()

        self.assertEqual("BUILD", pipeline.next_phase("BUILD", "RECOVERABLE"))
        self.assertEqual("ARTIFACT", pipeline.next_phase("BUILD", "SAFE_AUTO"))

    def test_theme_lane_is_recoverable_and_never_flashable(self):
        pipeline = ArthurPipeline()

        route = pipeline.classify_candidate_route(
            ".github/workflows/arthur-theme-candidate.yml",
            ["SHA256SUMS.local"],
        )

        self.assertEqual("RECOVERABLE_ROUTE_MISMATCH", route["route"])
        self.assertFalse(route["flash_allowed"])
        self.assertFalse(route["release_allowed"])
        self.assertIn("plugin-verification.txt", route["missing_evidence"])

    def test_production_lane_requires_complete_evidence(self):
        pipeline = ArthurPipeline()

        route = pipeline.classify_candidate_route(
            ".github/workflows/arthur-update-v3.yml",
            pipeline.production_candidate_evidence,
        )

        self.assertEqual("PRODUCTION_CANDIDATE", route["route"])
        self.assertTrue(route["flash_allowed"])
        self.assertTrue(route["release_allowed"])


if __name__ == "__main__":
    unittest.main()
