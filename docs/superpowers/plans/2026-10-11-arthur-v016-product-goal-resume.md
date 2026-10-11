# Arthur v0.1.6 Product-Goal Resume Implementation Plan

> **For agentic workers:** This plan is executed inline in the current task. Steps use checkbox syntax for tracking.

**Goal:** Resume exact-release product validation without rerunning the already-passed PostFlash verifier or its reboot.

**Architecture:** Add a separate manual workflow mode. It must bind the locally persisted evidence from run `38087541420` to the exact v0.1.6 release and a successful no-flash PostFlash step, then make read-only Ethernet/HTTP/strict-SSH identity checks before invoking the existing product-goal validator. The existing PostFlash mode and firmware payload remain unchanged.

**Tech Stack:** GitHub Actions YAML, PowerShell 7, existing Arthur SSH identity helper, PowerShell regression tests.

**Spec:** Current user request; `production/product-goal-contract.json`.

## Global Constraints

- Release identity is fixed: tag `v0.1.6`, source `b4448e62ab1e767f9a60221b0600c60c355baf56`, build `38000704263`, artifact `11655711894`, image SHA256 `e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39`, device MAC `dc:d8:7c:45:91:99`.
- Prior evidence must come from run `38087541420` and match every exact release identity field before reuse.
- The product-goal resume path must skip both flash-capable and PostFlash verifier steps; no Build, Release, firmware transfer, sysupgrade, or reboot.
- Identity checks use existing strict SSH trust and read-only commands; no password/key/known_hosts recovery.
- File-management evidence already marked PASS is carried forward from the exact bound report.

## Review Focus

- Missing or mismatched prior evidence: fail before device access.
- Prior run did not skip flash or did not pass PostFlash: fail closed.
- Ethernet, HTTP, or strict SSH identity mismatch: fail before runtime validation.
- Existing `resume_postflash_only` behavior: remain unchanged.
- Product-goal step running from the new mode without copied exact evidence: fail before Codex validation.

---

### Task 1: Bind and restore previous PostFlash evidence

**Files:** Create `scripts/arthur-product-goal-resume.ps1`; test in `tests/arthur-product-goal-resume.tests.ps1`.

**Interfaces:** The script accepts `-RequestPath` and fixed `-PreviousRunId 38087541420`. It validates the persisted `real-device-verification.json` and `v016-file-management-postflash.json`, then copies those exact files under `output/real-device/` without rewriting them.

- [x] Add tests for exact identity match, required PASS markers, and mismatched/missing identity failure.
- [x] Run the tests and confirm they fail because the binding script is absent.
- [x] Implement evidence and prior-run metadata validation; never call device write or reboot commands.
- [x] Run the tests and confirm all cases pass.

### Task 2: Add a product-goal-only workflow entry

**Files:** Modify `.github/workflows/arthur-post-release-device-test.yml`; extend `tests/arthur-postflash-resume-workflow.tests.ps1`.

**Interfaces:** Add manual input `resume_product_goal_only`; for that mode run evidence binding, then a strict read-only device identity preflight, then the existing product-goal validator. Keep the normal resume mode unchanged and do not run the flash or canonical PostFlash steps.

- [x] Add regression assertions for mode gating, step ordering, strict identity, no-flash/no-reboot boundaries, and reuse of file-management evidence.
- [x] Run the workflow test and confirm the new mode assertions fail.
- [x] Implement the gated steps and clarify prompt wording so prior file-management PASS is reused without revalidation.
- [x] Run both focused regression tests, `git diff --check`, and inspect the full diff for firmware/source changes.
- [ ] Commit and push only after the tests pass; then dispatch exactly one product-goal-only run.
