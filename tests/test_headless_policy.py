import unittest

from ai_orchestrator.models import ActionKind, GPTDecision
from ai_orchestrator.policy import DecisionValidationError, PolicyRoute, policy_gate, validate_decision


class HeadlessPolicyTests(unittest.TestCase):
    def test_build_failure_is_automatic_recovery(self):
        decision = validate_decision(
            {
                "action": "RECOVERABLE",
                "reason_code": "BUILD_ERROR",
                "summary": "Compiler error has a source-level repair.",
                "next_codex_prompt": "Inspect the first compiler error and apply the smallest compatible fix.",
                "evidence": ["output/logs/build.log"],
            }
        )

        outcome = policy_gate(decision)

        self.assertEqual(ActionKind.RECOVERABLE, decision.action)
        self.assertEqual(PolicyRoute.RECOVERABLE, outcome.route)
        self.assertIsNone(outcome.human_gate)

    def test_unknown_device_remains_a_human_gate(self):
        decision = validate_decision(
            {
                "action": "HUMAN_GATE",
                "reason_code": "UNKNOWN_DEVICE",
                "summary": "Device identity cannot be established safely.",
                "human_gate": "UNKNOWN_DEVICE_IDENTITY",
                "evidence": ["device/identity-failure.json"],
            }
        )

        outcome = policy_gate(decision)

        self.assertEqual(PolicyRoute.HUMAN_GATE, outcome.route)

    def test_design_approval_cannot_be_a_human_gate(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(
                {
                    "action": "HUMAN_GATE",
                    "reason_code": "DESIGN_APPROVAL",
                    "summary": "Please approve the design.",
                    "human_gate": "DESIGN_APPROVAL",
                    "evidence": ["design.md"],
                }
            )

    def test_auth_required_needs_automatic_discovery_evidence(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(
                {
                    "action": "HUMAN_GATE",
                    "reason_code": "AUTH_REQUIRED",
                    "summary": "Credentials are unavailable.",
                    "human_gate": "NEW_CREDENTIAL_PROVISIONING",
                    "evidence": ["preflight.json"],
                }
            )

        decision = validate_decision(
            {
                "action": "HUMAN_GATE",
                "reason_code": "AUTH_REQUIRED",
                "summary": "Automatic credential discovery failed.",
                "human_gate": "NEW_CREDENTIAL_PROVISIONING",
                "evidence": ["state/preflight.json"],
                "auth_resource": "OpenAI Responses API",
                "provider": "openai",
                "verification_error": "OPENAI_API_KEY is unset and SDK account has no usable controller model.",
                "credential_discovery_failed": True,
            }
        )

        self.assertEqual(PolicyRoute.HUMAN_GATE, policy_gate(decision).route)

    def test_malformed_controller_output_is_rejected(self):
        with self.assertRaises(DecisionValidationError):
            validate_decision(
                {
                    "action": "SAFE_AUTO",
                    "reason_code": "CONFIG",
                    "summary": "Missing next action.",
                    "evidence": [],
                }
            )


if __name__ == "__main__":
    unittest.main()
