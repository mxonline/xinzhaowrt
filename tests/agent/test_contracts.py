import unittest

from agent.contracts.validate import validate_document


class ContractValidationTests(unittest.TestCase):
    def test_valid_skill_contract(self):
        skill = {
            "id": "core.systematic-debugging",
            "version": "1.0.0",
            "layer": "core",
            "triggers": ["build_failed"],
            "non_triggers": ["build_verified"],
            "inputs": ["task_packet", "handoff"],
            "preconditions": ["evidence_available"],
            "permissions": ["read", "write"],
            "risk": "medium",
            "implementation": {"type": "vendor", "binding": "superpowers/systematic-debugging"},
            "evidence": ["root_cause", "tests"],
            "verification": ["targeted_test_pass"],
            "failure_handling": "fail_closed",
            "fallback": "handoff_resume",
        }
        self.assertEqual(validate_document("skill", skill), [])

    def test_skill_missing_permissions_fails(self):
        skill = {
            "id": "core.bad",
            "version": "1.0.0",
            "layer": "core",
            "triggers": [],
            "non_triggers": [],
            "inputs": [],
            "preconditions": [],
            "risk": "low",
            "implementation": {"type": "local", "binding": "none"},
            "evidence": [],
            "verification": [],
            "failure_handling": "fail_closed",
            "fallback": "none",
        }
        self.assertIn("permissions", " ".join(validate_document("skill", skill)))

    def test_unknown_skill_risk_fails(self):
        skill = {
            "id": "core.bad-risk",
            "version": "1.0.0",
            "layer": "core",
            "triggers": [],
            "non_triggers": [],
            "inputs": [],
            "preconditions": [],
            "permissions": ["read"],
            "risk": "extreme",
            "implementation": {"type": "local", "binding": "none"},
            "evidence": [],
            "verification": [],
            "failure_handling": "fail_closed",
            "fallback": "none",
        }
        self.assertIn("risk", " ".join(validate_document("skill", skill)))

    def test_valid_task_packet(self):
        packet = {
            "task_id": "task-001",
            "goal": "add a package",
            "project": "xinzhaowrt",
            "domain": "openwrt",
            "current_state": "READY",
            "requested_action": "modify_firmware",
            "constraints": ["preserve_known_good"],
            "risk": "medium",
            "resume_state": {},
        }
        self.assertEqual(validate_document("task_packet", packet), [])

    def test_valid_handoff(self):
        handoff = {
            "task_id": "task-001",
            "current_stage": "REAL_DEVICE_VERIFY",
            "stage_status": "FAILED",
            "verified_stages": ["BUILD", "CANDIDATE"],
            "failed_or_blocked_stage": "REAL_DEVICE_VERIFY",
            "evidence": ["evidence/real-device.json"],
            "next_skill": "core.systematic-debugging",
            "rollback_target": "arthur-known-good-v1",
            "last_updated": "2026-08-31T00:00:00Z",
        }
        self.assertEqual(validate_document("handoff", handoff), [])

    def test_valid_evidence(self):
        evidence = {
            "task_id": "task-001",
            "skill_id": "core.verification",
            "status": "PASS",
            "artifacts": [],
            "checks": [{"name": "unit-tests", "status": "PASS"}],
            "timestamp": "2026-08-31T00:00:00Z",
        }
        self.assertEqual(validate_document("evidence", evidence), [])


if __name__ == "__main__":
    unittest.main()
