# OpenWrt Automated Firmware Pipeline v4.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add machine-enforced batched-changeset hard gates so no production candidate can build, flash, verify, or release before the entire changeset is complete and frozen.

**Architecture:** `production/current-changeset.json` is the authorization state. `scripts/implementation-complete-gate.sh` validates task completion, freeze state and exact source SHA. Existing candidate entry points call the gate before expensive build work; tests assert that bypass paths are absent.

**Tech Stack:** Bash, Python 3, GitHub Actions YAML, JSON, existing Arthur SDK/ImageBuilder pipeline.

**Spec:** `docs/superpowers/specs/2026-08-31-openwrt-pipeline-v4.3-design.md`

## Global Constraints

- Production terminal state is `PRODUCTION_RELEASED`.
- No candidate build before `IMPLEMENTATION_COMPLETE_GATE=PASS` and `CHANGESET_FREEZE=PASS`.
- Current intermediate artifacts are not flash/release eligible.
- Do not change Arthur target/profile, storage layout, known-good or rollback artifacts.
- Standard automatic flashing remains PowerShell → `ssh.exe` → `/sbin/sysupgrade` after safety gates.

---

### Task 1: Add changeset state and gate tests

**Files:**
- Create: `production/current-changeset.json`
- Create: `tests/test-implementation-complete-gate.sh`

- [ ] Define current Arthur required tasks as PENDING and production permissions false.
- [ ] Add negative tests proving incomplete/unfrozen/wrong-SHA states are rejected.
- [ ] Add positive test proving a fully PASS frozen state bound to HEAD is accepted.

### Task 2: Implement machine hard gate

**Files:**
- Create: `scripts/implementation-complete-gate.sh`
- Modify: `scripts/check-changeset-complete.sh`

- [ ] Validate schema, required task states, completion flags, changeset id and frozen source SHA.
- [ ] Make `check-changeset-complete.sh` delegate final authorization to the new gate instead of declaring freeze by itself.

### Task 3: Protect candidate entry points

**Files:**
- Modify: `tests/test-fast-candidate-workflow.sh`
- Modify: `scripts/verify-project.sh`
- Existing: `.github/workflows/arthur-theme-candidate.yml`
- Existing: `.github/workflows/arthur-fast-candidate.yml`
- Existing: `.github/workflows/build.yml`

- [ ] Ensure theme candidate is blocked through `check-changeset-complete.sh`.
- [ ] Ensure fast candidate invokes hard gate before SDK/ImageBuilder work.
- [ ] Ensure generic Arthur build invokes hard gate before full build work.
- [ ] Keep development/static checks usable outside production candidate contexts.

### Task 4: Persist v4.3 policy

**Files:**
- Modify: `production/pipeline-policy.json`
- Create: `production/PIPELINE_V4.3.md`

- [ ] Record batched changeset policy and hard-gate requirements.
- [ ] Record one-build/one-flash/one-full-verify default and batch repair semantics.

### Task 5: Verify and adopt on active development branch

- [ ] Review the isolated branch diff against `codex/arthur-fast-candidate`.
- [ ] Verify no target/profile/raw-write/known-good/rollback files changed.
- [ ] Fast-forward `codex/arthur-fast-candidate` only after the v4.3 changes are internally consistent.
- [ ] Do not merge stale `main` as part of this task.
