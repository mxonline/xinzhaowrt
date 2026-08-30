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


if __name__ == "__main__":
    unittest.main()
