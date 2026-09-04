# Arthur Feature Handoff Terminal Continuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing Arthur Feature Handoff treat only `PRODUCTION_RELEASED` as terminal and let the existing Task Scheduler-owned `Resume` process continue through every intermediate checkpoint.

**Architecture:** Preserve the current `feature-handoff.ps1` state machine, `feature-handoff-lib.ps1` helpers, and `install-feature-handoff.ps1` Task Scheduler registration. Add compatibility normalization for externally persisted progress markers, make persistent monitoring block until the sole release terminal, and retain one-stage behavior only for explicit `RunOnce` diagnostics.

**Tech Stack:** PowerShell 7, Windows Task Scheduler, existing GitHub CLI/v3 controller/Production Agent integration, PowerShell contract tests.

**Spec:** User instruction in the current task: `PRODUCTION_RELEASED` is the only successful endpoint; `HANDOFF`, `LIVE_PREVIEW_PASS`, `PREBUILD_PASS`, `SOURCE_FROZEN`, and `CANDIDATE_READY` must continue automatically without duplicate dispatch/build or Wi-Fi verification.

## Global Constraints

- Reuse the existing persistent Feature Handoff implementation and Task Scheduler task.
- Do not create a new control plane, supervisor, bridge, or duplicate automation.
- Preserve the already-passed ADH LIVE_PREVIEW and `WIFI=VERIFIED_FROZEN` evidence.
- Do not repeat verified ADH/QuickStart/Wi-Fi stages or dispatch an already-bound run.
- Only `PRODUCTION_RELEASED` may terminate normal `Resume` execution.
- Safety-block only for the existing real safety conditions such as identity mismatch, missing rollback, failed `AUTO_FLASH_SAFETY_GATE`, or indeterminate flash state.

### Task 1: Add regression coverage for intermediate-marker continuation

**Files:**
- Modify: `tests/feature-handoff.tests.ps1`
- Modify: `tests/feature-handoff-auto-trigger.tests.ps1`

- [ ] **Step 1: Write failing assertions** for normalization of all five external markers and for persistent monitoring to omit `-OneShot` during `Resume`.
- [ ] **Step 2: Run the focused tests** and verify they fail because the normalization helper/continuous monitor contract is absent.

### Task 2: Implement continuation normalization and persistent monitoring

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`

- [ ] **Step 1: Add the minimal marker-to-existing-stage normalization helper** and invoke it when loading durable state.
- [ ] **Step 2: Thread the existing `RunOnce` switch into `Invoke-OneStage` so normal `Resume` monitors continuously while explicit diagnostics remain one-stage.
- [ ] **Step 3: Keep the current exact-once dispatch and safety reconciliation paths unchanged.**

### Task 3: Verify Task Scheduler ownership and all contracts

**Files:**
- Inspect: `scripts/install-feature-handoff.ps1`
- Modify: `tests/feature-handoff-task-privilege.tests.ps1` only if the regression exposes a real contract gap.

- [ ] **Step 1: Run focused Feature Handoff tests and full static contracts.**
- [ ] **Step 2: Register/verify the existing `XinZhaoWrt-Arthur-Feature-Handoff` task once and inspect its action is `feature-handoff.ps1 -Mode Resume`.
- [ ] **Step 3: Verify the durable state still references the existing run and no new dispatch/build/Wi-Fi action was initiated.

### Task 4: Final evidence and handoff

- [ ] **Step 1: Inspect `git diff --check` and the durable task/state evidence.
- [ ] **Step 2: Report only the observed terminal/blocked state; do not claim release until `PRODUCTION_RELEASED` is actually recorded.
