# Arthur ADH Resume Provenance Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the unattended Arthur Control Plane so it can safely reconcile current evidence and resume the current release from `ADH_MANAGEMENT`, then `ADH_CHINESE`, without repeating verified Wi-Fi work or losing the accepted iStore/QuickStart state.

**Architecture:** Keep the existing RELEASE-FIRST control plane, `production/resume-state.json`, AI Orchestrator runtime, and product targets. Do not add a second orchestrator or change build/flash semantics. First instrument the failing GitHub provenance boundary, then repair only the proven failing call. The current release checkpoint remains `ADH_MANAGEMENT -> ADH_CHINESE`; later stages continue only through existing gates.

**Tech Stack:** PowerShell 5.1/7 contract tests, GitHub Actions, GitHub CLI, existing Python AI Orchestrator.

**Spec:** `production/README.md`, `production/ARTHUR_PRODUCT_TARGETS.md`, `production/release-policy.md`

## Global Constraints

- Current physical development baseline remains XinZhaoWrt `0.1.3` until live evidence proves otherwise.
- Current release task is `arthur-adh-quickstart`.
- Resume checkpoint is `ADH_MANAGEMENT`; after it is VERIFIED, advance to `ADH_CHINESE`.
- Wi-Fi remains `VERIFIED_FROZEN`; do not repeat Wi-Fi implementation/verification during recovery.
- Preserve the accepted iStore/QuickStart product state; do not rebuild it as unrelated work.
- `production/resume-state.json` must remain fail-closed; no GPT/Codex execution instruction while `instruction_allowed != true`.
- No Build, Candidate, Flash, or Release duplication.
- Only success endpoint is `PRODUCTION_RELEASED`.
- Standard sysupgrade only; raw flash writes remain forbidden.

---

### Task 1: Pin the current ADH release checkpoint contract

**Files:**
- Modify: `tests/arthur-control-plane-executor.tests.ps1`
- Read only: `scripts/arthur-control-plane.ps1`, `ai_orchestrator/arthur.py`, `production/ARTHUR_PRODUCT_TARGETS.md`

**Interfaces:**
- Consumes: existing `arthur-adh-quickstart` runtime bootstrap and phase order.
- Produces: regression assertions proving recovery starts at `ADH_MANAGEMENT`, advances to `ADH_CHINESE`, freezes Wi-Fi, and preserves iStore/QuickStart intent.

- [ ] **Step 1: Write the failing-or-contract test**

Add exact assertions for the current release task identity, bootstrap `phase/current_stage/next_action = ADH_MANAGEMENT`, the `ADH_MANAGEMENT` before `ADH_CHINESE` order, `WIFI=VERIFIED_FROZEN`, and preserving iStore/QuickStart.

- [ ] **Step 2: Run the focused contract test**

Run: `pwsh -File tests/arthur-control-plane-executor.tests.ps1`
Expected: existing behavior may already satisfy some assertions; any missing machine contract must fail before production changes.

- [ ] **Step 3: Make only the minimum production change if a required contract is missing**

Do not move the checkpoint to Build or any later stage. Do not reimplement verified Wi-Fi/iStore work.

- [ ] **Step 4: Re-run the focused contract test**

Expected: PASS.

### Task 2: Locate the current GitHub provenance failure boundary

**Files:**
- Modify: `tests/arthur-control-plane-executor.tests.ps1`
- Modify: `scripts/arthur-control-plane.ps1`

**Interfaces:**
- Consumes: `Invoke-GhJson` and current GitHub provenance queries.
- Produces: explicit begin/pass markers around each GitHub provenance boundary so a live-run failure identifies the exact call without guessing.

- [ ] **Step 1: Write RED assertions**

Require these markers in the script:

```text
GITHUB_PROVENANCE_RUN_LIST=BEGIN
GITHUB_PROVENANCE_RUN_LIST=PASS
GITHUB_PROVENANCE_RELEASE_LIST=BEGIN
GITHUB_PROVENANCE_RELEASE_LIST=PASS
GITHUB_PROVENANCE_CANDIDATE_VIEW=BEGIN
GITHUB_PROVENANCE_CANDIDATE_VIEW=PASS
```

- [ ] **Step 2: Run the focused contract test and verify RED**

Run: `pwsh -File tests/arthur-control-plane-executor.tests.ps1`
Expected: FAIL because the boundary markers do not yet exist.

- [ ] **Step 3: Add only boundary logging**

Place begin/pass logs immediately around the three existing GitHub calls. Do not change query semantics yet.

- [ ] **Step 4: Run focused tests and Fast Preflight**

Expected: contract PASS and repository preflight PASS.

- [ ] **Step 5: Run one real self-hosted Control Plane wakeup**

Use the existing single wakeup workflow. Read the live log and identify the first `BEGIN` without its matching `PASS`.

### Task 3: Repair only the proven provenance call

**Files:**
- Modify: `tests/arthur-control-plane-executor.tests.ps1` or a focused new regression test if required.
- Modify: `scripts/arthur-control-plane.ps1` only if live evidence proves that file is the failing component.

**Interfaces:**
- Consumes: exact failure message and boundary marker from Task 2.
- Produces: one minimal provenance fix.

- [ ] **Step 1: Form one explicit root-cause hypothesis from the live log**

Record the exact failing command and error. No speculative multi-fix patch.

- [ ] **Step 2: Write a failing regression test for that exact defect**

Expected: RED for the proven bug only.

- [ ] **Step 3: Implement the minimum fix**

Do not change firmware content, build lane, flash policy, or current ADH checkpoint.

- [ ] **Step 4: Run focused tests, Fast Preflight, and Production Agent CI**

Expected: all PASS.

- [ ] **Step 5: Merge and verify on the real runner**

Required live evidence before claiming resume success:

```text
GITHUB_PROVENANCE ...
DEVICE_PROBE reachable=True classification=CURRENT ...
RESUME_STATE_RECONCILED=PASS ... checkpoint=ADH_MANAGEMENT ...
HEADLESS_RUNTIME_STARTING phase=ADH_MANAGEMENT ...
```

### Task 4: Continue the established release chain without skipping gates

**Files:** no speculative edits; use existing runtime/checkpoint files and workflow evidence.

**Interfaces:**
- Consumes: a live `RESUME_SAFE` snapshot and AI Orchestrator checkpoint.
- Produces: normal progression through the existing release chain.

- [ ] **Step 1: Complete and verify `ADH_MANAGEMENT`**

Use the mature `luci-app-adguardhome` implementation with minimal Arthur compatibility patches. AdGuard Home remains disabled by default.

- [ ] **Step 2: Advance to and verify `ADH_CHINESE`**

Chinese localization must be user-visible and complete for the intended management UI.

- [ ] **Step 3: Preserve frozen/accepted product state**

Do not redo Wi-Fi. Do not discard accepted iStore/QuickStart behavior.

- [ ] **Step 4: Continue existing gates**

`CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> ... -> BUILD -> ARTIFACT -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> REAL_DEVICE_VERIFY -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`.

- [ ] **Step 5: Final verification**

Do not claim completion unless real workflow/device evidence reaches `PRODUCTION_RELEASED`.
