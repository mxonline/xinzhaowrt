import unittest

from scripts.one_time_arthur_release_36348777394 import (
    validate_run_artifact_identity,
    verify_sha256_bytes,
)


class OneTimeArthurReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.run = {
            "databaseId": 36348777394,
            "headBranch": "codex/arthur-smart-build-20260928",
            "headSha": "b16ed00ffaed0df927fc5fe482a51153ad9e99d9",
            "workflowName": "Build XinZhaoWrt Arthur",
            "status": "completed",
            "conclusion": "success",
        }
        self.artifact_index = {
            "artifacts": [
                {
                    "id": 10944450704,
                    "name": "XinZhaoWrt-Arthur",
                    "expired": False,
                    "digest": "sha256:28784b993300f055685934473f32f740e889b30e60ad07b3e5a81e9caf358bd8",
                    "workflow_run": {
                        "id": 36348777394,
                        "head_sha": "b16ed00ffaed0df927fc5fe482a51153ad9e99d9",
                        "head_branch": "codex/arthur-smart-build-20260928",
                    },
                }
            ]
        }

    def test_accepts_only_the_exact_successful_build_and_artifact(self):
        validate_run_artifact_identity(self.run, self.artifact_index)

    def test_rejects_a_different_project_commit(self):
        self.run["headSha"] = "a" * 40
        with self.assertRaisesRegex(ValueError, "headSha"):
            validate_run_artifact_identity(self.run, self.artifact_index)

    def test_rejects_an_expired_artifact(self):
        self.artifact_index["artifacts"][0]["expired"] = True
        with self.assertRaisesRegex(ValueError, "expired"):
            validate_run_artifact_identity(self.run, self.artifact_index)

    def test_rejects_a_different_artifact_archive_digest(self):
        self.artifact_index["artifacts"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "archive digest"):
            validate_run_artifact_identity(self.run, self.artifact_index)

    def test_rejects_a_different_artifact_id(self):
        self.artifact_index["artifacts"][0]["id"] = 10944450705
        with self.assertRaisesRegex(ValueError, "artifact ID"):
            validate_run_artifact_identity(self.run, self.artifact_index)

    def test_sha256_check_rejects_changed_bytes(self):
        with self.assertRaisesRegex(ValueError, "SHA256"):
            verify_sha256_bytes(b"changed payload", "0" * 64)


if __name__ == "__main__":
    unittest.main()
