#!/usr/bin/env python3
"""Guard the v0.1.6 build against replacing Stable UI bytes with old preview bytes."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/derive-stable-overlay-manifest.py"
SOURCE = "b4448e62ab1e767f9a60221b0600c60c355baf56"


def run(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def must_pass(result):
    assert result.returncode == 0, result.stdout + result.stderr


def must_fail(result, marker):
    assert result.returncode != 0, result.stdout + result.stderr
    assert marker in result.stdout + result.stderr, result.stdout + result.stderr


with tempfile.TemporaryDirectory() as temp:
    output = Path(temp) / "stable-overlay.json"
    result = run(sys.executable, str(HELPER), "--root", str(ROOT), "--source-sha", SOURCE, "--output", str(output))
    must_pass(result)
    assert "STABLE_OVERLAY_INHERITANCE=PASS" in result.stdout
    original = json.loads((ROOT / "production/accepted-preview/arthur-adh-quickstart.json").read_text(encoding="utf-8"))
    derived = json.loads(output.read_text(encoding="utf-8"))
    assert len(derived["frozen_files"]) == len(original["frozen_files"]) == 51
    assert derived["inherited_from_source_sha"] == "0eeae67f74db77a6401b0205d74e6518b899a3e4"
    assert derived["inherited_to_source_sha"] == SOURCE
    assert any(a["sha256"] != b["sha256"] for a, b in zip(original["frozen_files"], derived["frozen_files"]))
    must_pass(run(sys.executable, str(ROOT / "scripts/materialize-accepted-overlay.py"),
                  "--root", str(ROOT), "--manifest", str(output), "--check"))

    for suffix, mutation, expected in (
        ("wrong-source", ["--source-sha", "0" * 40], "frozen source identity mismatch"),
        ("wrong-baseline", ["--baseline-sha", "0" * 40], "baseline source identity mismatch"),
    ):
        bad_output = Path(temp) / (suffix + ".json")
        must_fail(run(sys.executable, str(HELPER), "--root", str(ROOT), "--source-sha", SOURCE,
                      "--output", str(bad_output), *mutation), expected)
        assert not bad_output.exists()

    fixture = Path(temp) / "fixture"
    fixture.mkdir()
    must_pass(run("git", "init", "-q", str(fixture)))
    must_pass(run("git", "config", "user.name", "Test", cwd=fixture))
    must_pass(run("git", "config", "user.email", "test@example.invalid", cwd=fixture))
    for subdir in ("files/etc", "production/accepted-preview"):
        (fixture / subdir).mkdir(parents=True)
    overlay = fixture / "files/etc/verified.txt"
    overlay.write_text("Stable verified bytes\n", encoding="utf-8")
    manifest = {"frozen_files": [{"overlay": "files/etc/verified.txt", "sha256": "0" * 64, "mode": "0644"}]}
    (fixture / "production/accepted-preview/arthur-adh-quickstart.json").write_text(json.dumps(manifest), encoding="utf-8")
    must_pass(run("git", "add", ".", cwd=fixture))
    must_pass(run("git", "commit", "-qm", "Stable", cwd=fixture))
    stable = run("git", "rev-parse", "HEAD", cwd=fixture).stdout.strip()
    (fixture / "production/file-management-expected-diff.json").write_text(
        json.dumps({"baseline_source_sha": stable, "target_release": "v0.1.6"}), encoding="utf-8")
    (fixture / "production/product-goal-verification.json").write_text(
        json.dumps({"status": "PRODUCT_GOAL_VERIFIED", "source_commit": stable}), encoding="utf-8")
    must_pass(run("git", "add", ".", cwd=fixture))
    must_pass(run("git", "commit", "-qm", "Candidate", cwd=fixture))
    candidate = run("git", "rev-parse", "HEAD", cwd=fixture).stdout.strip()
    (fixture / "production/operator-intent.json").write_text(json.dumps({
        "target_release": "v0.1.6",
        "firmware_state": {"active_source_sha": candidate},
        "highest_machine_evidence": {"accepted_source_sha": candidate},
    }), encoding="utf-8")
    fixture_output = Path(temp) / "fixture-overlay.json"
    must_pass(run(sys.executable, str(HELPER), "--root", str(fixture),
                  "--source-sha", candidate, "--output", str(fixture_output)))
    fixture_output.unlink()
    overlay.write_text("Changed after freeze\n", encoding="utf-8")
    must_pass(run("git", "add", ".", cwd=fixture))
    must_pass(run("git", "commit", "-qm", "Post-freeze drift", cwd=fixture))
    must_fail(run(sys.executable, str(HELPER), "--root", str(fixture),
                  "--source-sha", candidate, "--output", str(fixture_output)),
              "protected Stable overlay changed after source freeze")
    assert not fixture_output.exists()

print("STABLE_OVERLAY_INHERITANCE_TEST=PASS")
