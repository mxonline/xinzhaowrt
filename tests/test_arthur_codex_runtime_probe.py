import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "arthur-codex-runtime-probe.py"


class ArthurCodexRuntimeProbeTests(unittest.TestCase):
    def test_probe_source_never_invokes_firmware_runtime(self):
        text = PROBE.read_text(encoding="utf-8")
        self.assertNotIn("run-production", text)
        self.assertNotIn("ai_orchestrator resume", text)
        self.assertNotIn("sysupgrade", text)

    def test_probe_reports_expected_code_root_and_explicit_model(self):
        env = os.environ.copy()
        env["ARTHUR_CONTROL_PLANE_CODE_ROOT"] = str(ROOT)
        env["HEADLESS_CODEX_MODEL"] = "gpt-5.6-terra"
        env["ARTHUR_PROBE_SKIP_ACCOUNT"] = "1"
        completed = subprocess.run(
            [sys.executable, str(PROBE)],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        payload = json.loads(completed.stdout)
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(Path(payload["ai_orchestrator_file"]).resolve().is_relative_to(ROOT.resolve()))
        self.assertEqual(payload["configured_model"], "gpt-5.6-terra")
        self.assertEqual(payload["effective_model"], "gpt-5.6-terra")
        self.assertTrue(payload["model_catalog_skipped"])
        self.assertEqual(payload["exit_class"], "PROBE_OK")


if __name__ == "__main__":
    unittest.main()
