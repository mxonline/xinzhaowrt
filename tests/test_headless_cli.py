import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from ai_orchestrator.cli import _model_ids, main
from ai_orchestrator.state_store import StateStore


class HeadlessCLITests(unittest.TestCase):
    def test_status_reads_the_persisted_runtime_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory))
            store.snapshot_path.write_text(
                json.dumps(
                    {
                        "schema_version": "2.0",
                        "request_id": "cli-test",
                        "device": "jdcloud_re-ss-01",
                        "phase": "BUILD",
                        "next_codex_prompt": "build",
                    }
                ),
                encoding="utf-8",
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = main(["status", "--state-dir", directory])

            self.assertEqual(0, result)
            self.assertEqual("BUILD", json.loads(output.getvalue())["phase"])

    def test_stop_only_creates_a_stop_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            result = main(["stop", "--state-dir", directory])

            self.assertEqual(0, result)
            self.assertTrue((Path(directory) / "STOP").exists())

    def test_model_probe_normalization_accepts_sdk_json_value_wrappers(self):
        self.assertEqual(
            ["gpt-5.6-sol"],
            _model_ids({"data": [{"id": {"value": "gpt-5.6-sol"}}]}),
        )


if __name__ == "__main__":
    unittest.main()
