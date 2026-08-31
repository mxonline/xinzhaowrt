# OpenWrt Automated Firmware Pipeline v4.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent incomplete Arthur changesets from producing a flashable production candidate and enforce one batched build/flash/verify cycle after implementation freeze.

**Architecture:** Store required-task state in `production/current-changeset.json`. A single shell hard gate validates task completion, freeze state, changeset identity, and optional source SHA. Every production-candidate workflow must checkout an explicitly supplied frozen SHA and invoke the gate before any SDK/ImageBuilder/Full Build step.

**Tech Stack:** GitHub Actions YAML, POSIX/Bash shell, Python 3 JSON parsing, existing Arthur build workflows.

**Spec:** `docs/superpowers/specs/2026-08-31-openwrt-pipeline-v4.3-design.md`

## Global Constraints

- `PRODUCTION_RELEASED` is the only final success state.
- Current changeset starts incomplete and unfrozen.
- Candidate generation is denied until every required task is `PASS`, `implementation_complete=true`, and `frozen=true`.
- Candidate workflows bind to explicit `source_sha` and `changeset_id`.
- No production build may bypass the hard gate.
- Existing Arthur baseline behavior must not be changed by the gate implementation.

---

### Task 1: Hard-gate behavior tests

**Files:**
- Create: `tests/test-implementation-complete-gate.sh`

**Interfaces:**
- Consumes: `scripts/implementation-complete-gate.sh <state-file> [expected-changeset-id] [expected-source-sha]`
- Produces: executable behavior contract for later tasks.

- [ ] Write tests covering missing script/state, pending task, false implementation flag, false frozen flag, changeset mismatch, source SHA mismatch, and fully valid state.
- [ ] Run the test before implementation and verify RED because the gate script does not exist.
- [ ] Preserve the failing result as the TDD baseline.

### Task 2: Changeset state and implementation gate

**Files:**
- Create: `production/current-changeset.json`
- Create: `scripts/implementation-complete-gate.sh`

**Interfaces:**
- Consumes: current changeset JSON and optional expected identifiers.
- Produces: exit `0` plus `IMPLEMENTATION_COMPLETE_GATE=PASS` only when all required conditions pass; otherwise exit non-zero with a specific reason.

- [ ] Add the current Arthur required tasks, all initially `PENDING`, with `implementation_complete=false` and `frozen=false`.
- [ ] Implement strict JSON validation using Python 3 so no `jq` dependency is required.
- [ ] Reject missing/empty task maps, unknown non-PASS task states, false completion/freeze flags, ID mismatch, and source SHA mismatch.
- [ ] Run `tests/test-implementation-complete-gate.sh` and verify GREEN.

### Task 3: Production-candidate workflow entry contract

**Files:**
- Modify: `.github/workflows/arthur-theme-candidate.yml`
- Modify: `.github/workflows/arthur-fast-candidate.yml`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `source_sha`, `changeset_id`, `confirm=BUILD_FROZEN_CHANGESET`.
- Produces: all production build lanes share the same hard-gate behavior before build work begins.

- [ ] Remove/disable push-triggered production candidate behavior.
- [ ] Add explicit dispatch inputs for frozen source SHA and changeset ID.
- [ ] Checkout the supplied SHA rather than implicit branch HEAD.
- [ ] Verify checkout HEAD equals `source_sha`.
- [ ] Run `scripts/implementation-complete-gate.sh production/current-changeset.json "$changeset_id" "$source_sha"` before toolchain download or compilation.
- [ ] Deny build unless `confirm=BUILD_FROZEN_CHANGESET`.

### Task 4: CI regression tests for workflow wiring

**Files:**
- Create: `tests/test-v43-workflow-hard-gate.sh`
- Create/Modify: `.github/workflows/v43-gate-ci.yml`

**Interfaces:**
- Consumes: production workflow YAML files.
- Produces: static regression proof that each production lane has the required inputs, explicit SHA checkout, and implementation gate call.

- [ ] Add assertions for all three production workflows.
- [ ] Run shell syntax checks and both v4.3 test scripts.
- [ ] Verify the intentionally incomplete checked-in changeset causes the implementation gate to fail when invoked as a production gate, while unit fixtures still prove a valid frozen state passes.

### Task 5: Documentation and status

**Files:**
- Modify: `knowledge/OPENWRT-PRODUCTION-V4.md` or add a v4.3 section without deleting prior history.

**Interfaces:**
- Produces: operator-facing rule that development commits/preflight may run, but candidate build/flash begins only after hard-gate freeze.

- [ ] Document the v4.3 state machine, one-build/one-flash batched changeset rule, and batch-repair loop.
- [ ] Mark run `33396664381` as intermediate/non-production in the migration notes.
- [ ] Run final verification of tests and workflow static checks before claiming implementation complete.