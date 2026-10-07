import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class LiveE2EContractTests(unittest.TestCase):
    def test_separate_daemon_process_chains_three_turns_without_user_message(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [
                sys.executable,
                "-m",
                "ai_orchestrator",
                "run-production",
                "arthur",
                "--adapter",
                "loopback-live",
                "--state-dir",
                directory,
                "--max-turns",
                "3",
            ]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            events = [json.loads(line) for line in (Path(directory) / "events.jsonl").read_text(encoding="utf-8").splitlines()]
            executor = [event for event in events if event["event_type"] == "executor_result"]
            decisions = [event for event in events if event["event_type"] == "controller_decision"]
            automatic = [event for event in events if event["event_type"] == "next_turn"]

            self.assertEqual(3, len(executor))
            self.assertEqual(3, len(decisions))
            self.assertEqual(2, len(automatic))
            self.assertTrue(all(item["payload"]["source"] == "executor" for item in executor))
            self.assertTrue(all(item["payload"]["reviewed_by"] == "controller" for item in decisions))
            self.assertTrue(all(item["payload"]["next_action_generated_by"] == "controller" for item in automatic))
            self.assertTrue(all(item["payload"]["next_turn_started_automatically"] is True for item in automatic))


if __name__ == "__main__":
    unittest.main()
