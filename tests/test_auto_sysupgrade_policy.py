import unittest

from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.policy import DecisionValidationError, PolicyRoute, policy_gate, validate_decision


SHA256 = "88f8ce4588a928988b88bd6777293f50c73852540fff037616916db41751fa39"


def candidate_metadata():
    return {
        "filename": "XinZhaoWrt-Arthur-theme-33316789858-sysupgrade.bin",
        "sha256": SHA256,
        "size_bytes": 98_539_795,
        "target": "qualcommax/ipq60xx",
        "profile": "jdcloud_re-ss-01",
        "build_report": "candidate/build-report.json",
        "package_report": "candidate/package-report.json",
        "theme_report": "candidate/theme-report.json",
        "lan_static_report": "candidate/lan-static-report.json",
        "rollback_report": "candidate/rollback-report.json",
        "flash_manifest": "candidate/flash-manifest.json",
    }


def safety_checks(**overrides):
    checks = {
        "device_identity": True,
        "mac_match": True,
        "model_match": True,
        "storage_layout_verified": True,
        "candidate_complete": True,
        "candidate_size_match": True,
        "cloud_sha256": SHA256,
        "local_sha256": SHA256,
        "remote_sha256": SHA256,
        "ssh_control_channel": True,
        "plugins_22": True,
        "argon": True,
        "kucat": True,
        "known_good_available": True,
        "rollback_ready": True,
        "rollback_sha256_verified": True,
        "current_recovery_address": "192.168.1.1",
        "recovery_address_classification": "KNOWN_LAN_REGRESSION",
        "expected_post_flash_lan": "192.168.6.1",
    }
    checks.update(overrides)
    return checks


def auto_flash_decision(**overrides):
    candidate = candidate_metadata()
    checks = safety_checks(**overrides)
    return {
        "action": "SAFE_AUTO",
        "reason_code": "AUTO_FLASH_SAFETY_GATE",
        "summary": "All standard sysupgrade safety checks passed.",
        "next_codex_prompt": "Execute the verified standard sysupgrade and continue to WAIT_DEVICE.",
        "evidence": ["candidate/flash-manifest.json", "candidate/SHA256SUMS.local"],
        "metadata": {
            "candidate": candidate,
            "safety_gate": checks,
            "next_phase": "FLASH",
        },
    }


class AutoSysupgradePolicyTests(unittest.TestCase):
    def test_standard_sysupgrade_auto_runs_after_safety_gate(self):
        outcome = policy_gate(validate_decision(auto_flash_decision()))

        self.assertEqual(PolicyRoute.SAFE_AUTO, outcome.route)
        self.assertIsNone(outcome.human_gate)

    def test_no_human_gate_for_verified_sysupgrade(self):
        decision = validate_decision(auto_flash_decision())

        self.assertIsNone(decision.human_gate)
        self.assertEqual("FLASH", decision.metadata["next_phase"])

    def test_hash_mismatch_blocks_auto_flash(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(auto_flash_decision(local_sha256="0" * 64))

    def test_unknown_device_blocks_auto_flash(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(auto_flash_decision(device_identity=False))

    def test_verified_recovery_address_is_not_unknown_device(self):
        outcome = policy_gate(validate_decision(auto_flash_decision()))

        self.assertEqual(PolicyRoute.SAFE_AUTO, outcome.route)

    def test_remote_sha_required_before_auto_flash(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(auto_flash_decision(remote_sha256=None))

    def test_verified_rollback_sysupgrade_is_automatic(self):
        decision = auto_flash_decision()
        decision["reason_code"] = "AUTO_ROLLBACK_SAFETY_GATE"
        decision["metadata"]["next_phase"] = "ROLLBACK"

        outcome = policy_gate(validate_decision(decision))

        self.assertEqual(PolicyRoute.SAFE_AUTO, outcome.route)
        self.assertIsNone(outcome.human_gate)

    def test_auto_flash_continues_to_real_device_verify(self):
        pipeline = ArthurPipeline()

        self.assertNotIn("REAL_FLASH_WRITE_APPROVAL", pipeline.phases)
        self.assertLess(pipeline.phases.index("FLASH"), pipeline.phases.index("WAIT_DEVICE"))
        self.assertLess(pipeline.phases.index("WAIT_DEVICE"), pipeline.phases.index("IDENTIFY"))

    def test_real_device_pass_continues_to_release(self):
        pipeline = ArthurPipeline()

        self.assertLess(pipeline.phases.index("SYSTEM_HEALTH"), pipeline.phases.index("RELEASE_GATE"))
        self.assertLess(pipeline.phases.index("RELEASE_GATE"), pipeline.phases.index("RELEASE"))

    def test_pipeline_finishes_only_at_production_released(self):
        pipeline = ArthurPipeline()

        self.assertEqual("PRODUCTION_RELEASED", pipeline.phases[-1])
        self.assertNotIn("WAITING_FLASH_APPROVAL", pipeline.phases)
        self.assertNotIn("MANUAL_FLASH_REQUIRED", pipeline.phases)


if __name__ == "__main__":
    unittest.main()
