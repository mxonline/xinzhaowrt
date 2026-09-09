# Terminal Release Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close any completed Arthur production execution atomically and idempotently from durable release evidence, never resuming it at an actionable pre-release checkpoint.

**Architecture:** Add a single PowerShell `Invoke-ArthurTerminalReleaseReconcile` helper beside the existing resume/intent helpers. It validates a server-side GitHub Actions release evidence record against status, known-good and durable device evidence; then it atomically rewrites canonical resume/intent/runtime state and appends one hash-ledger event. Existing production promotion and `Complete-Release` invoke the same helper.

**Tech Stack:** PowerShell 7, JSON, existing Arthur firmware-event ledger, GitHub Actions `GITHUB_TOKEN`, Pester-style repository test scripts.

**Spec:** `docs/superpowers/specs/2026-09-09-terminal-release-reconciliation-design.md`

## Global Constraints

- Work only in `codex/terminal-release-reconciler`; never alter the old dirty checkout.
- Never create a build, candidate, flash, device verification, or release.
- Server-side GitHub Actions verifies release metadata with `GITHUB_TOKEN`; local reconciler has no REST, PAT, `gh auth`, credential-manager, or GitHub App fallback.
- Preserve frozen production identity and append ledger history only once per `(event, run_id, stable_tag)`.

---

### Task 1: Define failing terminal reconciliation contracts

**Files:**
- Create: `tests/arthur-terminal-release-reconciler.tests.ps1`
- Modify: `tests/test_arthur_codex_runtime_probe.py`

- [ ] Write fixtures for matching `status`, `known-good`, release evidence, device evidence, stale resume/intent/runtime, and a new execution ID.
- [ ] Assert the five required behaviors: forward closure; idempotent second invocation; fail-closed missing/mismatched release; runtime supersession; and independent new execution eligibility.
- [ ] Add a `relative_to` compatibility helper in the Python probe test so Python 3.8 can run the existing suite.
- [ ] Run the new PowerShell test and confirm it fails because `Invoke-ArthurTerminalReleaseReconcile` is absent.

### Task 2: Implement one terminal reconciler

**Files:**
- Create: `scripts/arthur-terminal-release-reconciler.ps1`
- Modify: `scripts/arthur-resume-state.ps1`
- Modify: `scripts/arthur-operator-intent.ps1`

- [ ] Implement evidence identity validation for tag, run, project/source commit, firmware name/SHA256, `known_good`, `verified`, and `real-device-confirmed`.
- [ ] Return a fail-closed result without writes for any mismatch.
- [ ] Produce canonical terminal resume/intent snapshots and close only the matching execution ID.
- [ ] Append an exactly-once terminal ledger event through the existing hash-chain ledger helper.
- [ ] Run the Task 1 tests to confirm all pass.

### Task 3: Wire server-side and local runtime closure

**Files:**
- Modify: `scripts/production-agent.ps1`
- Modify: `.github/workflows/promote-stable-v3.yml`
- Modify: `scripts/arthur-control-plane.ps1`

- [ ] Have `Complete-Release` invoke the reconciler after saved production evidence.
- [ ] Have the promotion workflow write verified release evidence using `GITHUB_TOKEN` and invoke the reconciler in the same state-only commit path.
- [ ] On runtime/control-plane load, supersede only stale state belonging to the completed execution; never bypass validation for another execution.
- [ ] Run reconciliation and production-agent static tests.

### Task 4: Validate and publish

**Files:**
- Modify: `production/resume-state.json`
- Modify: `production/operator-intent.json`
- Modify: `production/firmware-events.jsonl`
- Modify: `production/evidence/arthur-final-release-5f41c4e-20260908/index.json`

- [ ] Use only existing production identity `arthur-production-34268801985` / run `34268801985` to perform one terminal reconciliation.
- [ ] Run all relevant PowerShell, Python, resolver, control-plane, and idempotency tests.
- [ ] Commit, push the isolated branch, open a PR, and wait for CI before merge.
- [ ] Verify the merged `main` files and release evidence report `PRODUCTION_RELEASED / NONE` with no duplicate build, flash, release, or event.
