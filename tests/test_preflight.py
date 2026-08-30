import json
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.preflight import inspect_project


class PreflightTests(unittest.TestCase):
    def test_valid_arthur_project_has_target_profile_and_22_plugin_baseline(self):
        report = inspect_project(Path.cwd())

        self.assertTrue(report["checks"]["source_tree"])
        self.assertTrue(report["checks"]["target_profile"])
        self.assertTrue(report["checks"]["known_good"])
        self.assertEqual(22, report["checks"]["required_plugins"])

    def test_missing_source_tree_is_environment_blocker_not_auth_required(self):
        with tempfile.TemporaryDirectory() as directory:
            report = inspect_project(Path(directory))

            self.assertEqual("INVALID_ENVIRONMENT", report["status"])
            self.assertNotEqual("AUTH_REQUIRED", report["status"])
            self.assertFalse(report["checks"]["source_tree"])


if __name__ == "__main__":
    unittest.main()
