# Arthur Unattended Candidate Failure Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a failed formal Arthur Candidate automatically route from the existing Windows self-hosted Control Plane into the existing v3 Codex repair controller, and require a source/config closure preflight before a replacement Candidate can be dispatched.

**Architecture:** Reuse the existing Candidate fingerprint resolver, Windows `Arthur Runner Control Plane Wakeup`, `ci-controller-v3.ps1`, and v3 auto-trigger. Add no new production stage or controller. The fingerprint resolver gains an explicit failed-run action; the Control Plane converts that action into an idempotent launch of the existing repair controller; the controller must pass a build-closure preflight that stops after source/feed/package setup plus `make defconfig` and `check-config.sh` before it may request a replacement Candidate.

**Tech Stack:** Bash, PowerShell 7, Python unittest, GitHub Actions, GitHub CLI, existing Codex CLI/SDK runtime.

**Spec:** `production/release-policy.md`

## Global Constraints

- Unique success endpoint remains `PRODUCTION_RELEASED`.
- Do not create a new Gate, Agent, Controller, Runtime stage, or workflow stage in the frozen production order.
- Reuse the existing Windows self-hosted Runner wakeup and `ci-controller-v3.ps1` repair controller.
- Never dispatch a duplicate same-fingerprint Candidate.
- Wi-Fi remains `VERIFIED_FROZEN`; no wireless mutation/reload is introduced.
- Mature ADH, LuCI Chinese, and official QuickStart are not redeveloped.
- No sysupgrade is permitted before the formal PRE_FLASH / AUTO_FLASH_SAFETY_GATE path.

---

### Task 1: Classify failed same-fingerprint Candidate as repairable

**Files:**
- Modify: `scripts/resolve-candidate-dedup.sh`
- Modify: `.github/workflows/arthur-update-v3-auto.yml`
- Modify: `ai_orchestrator/recovery.py`
- Modify: `tests/test-build-dedup-contract.sh`
- Modify: `tests/test_codex_auto_recovery.py`
- Modify: `.github/workflows/arthur-fast-preflight.yml`

**Interfaces:**
- Produces `ACTION=REPAIR_FAILED_RUN`, `RUN_ID=<id>`, `BUILD_FINGERPRINT=<fingerprint>`, `SOURCE_SHA=<current source>` for the newest completed non-success Candidate with the same build fingerprint.
- `RecoverySupervisor.reconcile()` produces `next_action=AUTO_REPAIR_FAILED_CANDIDATE` for the same evidence class.
- The v3 auto-trigger consumes `REPAIR_FAILED_RUN` as a no-dispatch outcome.

- [ ] Write tests asserting failed same-fingerprint runs route to repair and never to `NEW_CANDIDATE`.
- [ ] Run PR Fast Preflight and verify RED before implementation.
- [ ] Implement the minimal resolver/recovery/auto-trigger changes.
- [ ] Run Fast Preflight and Python recovery tests and verify GREEN.

### Task 2: Wire Windows Control Plane to existing v3 repair controller

**Files:**
- Create: `scripts/arthur-candidate-failure-recovery.ps1`
- Modify: `scripts/arthur-control-plane-gate.ps1`
- Modify: `.github/workflows/arthur-fast-preflight.yml`
- Create: `tests/arthur-candidate-failure-recovery.tests.ps1`
- Modify: `scripts/classify-build-scope.sh`

**Interfaces:**
- Live helper consumes `resolve-candidate-dedup.sh` output from the persistent task workspace.
- On `REPAIR_FAILED_RUN`, helper starts exactly one hidden `ci-controller-v3.ps1 -Mode Resume -RunId <id>` process and persists PID/run identity under the existing Control Plane state root.
- Repeated five-minute wakeups return `ALREADY_RUNNING` while the same repair process is alive; they do not launch duplicates.
- Other resolver actions return `NOT_REQUIRED` and continue the normal Control Plane path.

- [ ] Write PowerShell tests for `NOT_REQUIRED`, `STARTED`, and `ALREADY_RUNNING` decision behavior without launching real Codex.
- [ ] Run Fast Preflight and verify RED.
- [ ] Implement the helper and gate wiring with process/PID idempotency.
- [ ] Run Fast Preflight and verify GREEN.

### Task 3: Add exact source/config closure preflight before replacement Candidate

**Files:**
- Modify: `scripts/build.sh`
- Modify: `scripts/ci-controller-v3.ps1`
- Create: `tests/test-build-closure-preflight.sh`
- Modify: `.github/workflows/arthur-fast-preflight.yml`

**Interfaces:**
- `BUILD_CLOSURE_ONLY=1 ./scripts/build.sh` performs the same locked source checkout, feeds, custom package staging, source provenance, package existence, overlay, Arthur config application, `make defconfig`, and `scripts/check-config.sh`, then exits before `make download` and firmware compilation.
- After Codex repair and before replacement dispatch, `ci-controller-v3.ps1` runs the closure mode; a failure returns to the same repair loop instead of dispatching a Candidate.
- Successful closure emits `BUILD_CLOSURE_PREFLIGHT=PASS` and is the only path that permits replacement Candidate dispatch.

- [ ] Write a contract test proving closure mode stops before download/compile and is invoked by the repair controller before replacement dispatch.
- [ ] Run Fast Preflight and verify RED.
- [ ] Implement closure mode and controller invocation.
- [ ] Run Fast Preflight and verify GREEN.

### Task 4: End-to-end unattended deployment verification

**Files:**
- No new production subsystem.
- Verify existing `.github/workflows/production-agent-deploy.yml` self-hosted wakeup behavior after merge.

**Interfaces:**
- Merge to `main` causes the existing five-minute self-hosted wakeup to fast-forward clean Control Plane code automatically.
- A controlled failed-run decision must produce durable evidence that the Windows runner started the existing repair controller without a chat message or manual Codex prompt.

- [ ] Verify PR CI is green.
- [ ] Merge only after review/verification.
- [ ] Observe a fresh self-hosted `Arthur Runner Control Plane Wakeup` run on the merge SHA and confirm code sync.
- [ ] Confirm the failed Candidate is routed to repair automatically; do not create a replacement Candidate until closure preflight passes.
