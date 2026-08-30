"""Run the independent-process LIVE_E2E contract without opening Codex UI."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def run_live_e2e():
    with tempfile.TemporaryDirectory(prefix="xinzhaowrt-live-e2e-") as directory:
        result = subprocess.run(
            [
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
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr or result.stdout)
        events = [json.loads(line) for line in (Path(directory) / "events.jsonl").read_text(encoding="utf-8").splitlines()]
        executor = [event for event in events if event["event_type"] == "executor_result"]
        decisions = [event for event in events if event["event_type"] == "controller_decision"]
        next_turns = [event for event in events if event["event_type"] == "next_turn"]
        if len(executor) < 3 or len(decisions) < 3 or len(next_turns) < 2:
            raise RuntimeError("LIVE_E2E did not produce three executor/controller pairs")
        if not all(item["payload"].get("source") == "executor" for item in executor):
            raise RuntimeError("executor provenance missing")
        if not all(item["payload"].get("reviewed_by") == "controller" for item in decisions):
            raise RuntimeError("controller provenance missing")
        if not all(item["payload"].get("next_action_generated_by") == "controller" for item in next_turns):
            raise RuntimeError("controller next-action provenance missing")
        if not all(item["payload"].get("next_turn_started_automatically") is True for item in next_turns):
            raise RuntimeError("automatic continuation evidence missing")
        print("LIVE_E2E=PASS")
        print("EXECUTOR_TURNS=%d" % len(executor))
        print("CONTROLLER_DECISIONS=%d" % len(decisions))


if __name__ == "__main__":
    run_live_e2e()
