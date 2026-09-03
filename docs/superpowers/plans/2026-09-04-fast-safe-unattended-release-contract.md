# Fast Safe Unattended Release Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce one machine-level contract so Arthur and future XinZhaoWrt firmware work reaches `PRODUCTION_RELEASED` as quickly as possible without repeating valid preview/build/flash work and without weakening device, artifact, rollback, plugin/config/theme, or post-flash safety.

**Architecture:** Extend the existing Feature Handoff runtime, `scripts/ci-controller-v3.ps1`, `scripts/production-agent.ps1`, and existing Arthur workflows. Add one shared machine policy plus fingerprint/invalidation/recovery primitives; do not add a production stage, Gate, workflow owner, Supervisor, or parallel release architecture.

**Tech Stack:** PowerShell 7 and existing Windows PowerShell-compatible runtime code, Bash, JSON, Git/GitHub CLI, GitHub Actions, Windows Scheduled Tasks.

**Spec:** `docs/superpowers/specs/2026-09-04-fast-safe-unattended-release-contract-design.md`

## Global Constraints

- Only successful terminal state: `PRODUCTION_RELEASED`.
- Preserve the existing RELEASE-FIRST stage order exactly.
- Recovery law: `REUSE → RECONCILE → REPAIR → CONTINUE`.
- A VERIFIED checkpoint may regress only when durable invalidation evidence names the changed input and minimum repeat scope.
- `HANDOFF.md`, Markdown docs, PR metadata, executor/session state, and control-plane-only edits must not invalidate preview/build bytes.
- Same accepted-preview fingerprint must skip source rediscovery and complete preview redeployment.
- Same build fingerprint must watch an existing run, reuse a valid artifact, or revalidate a quarantined Candidate before considering a rebuild.
- `FLASH_STARTED`, `WAIT_DEVICE`, and `REAL_DEVICE_VERIFY` recovery must reconcile the existing write chain; never start a second flash chain.
- A deterministic safe `next_action` is not a legal terminal condition.
- Implementation must attach to an active release by adopting its run/artifact/state; activation must not cancel or duplicate existing work.

---

## Exact files

**Create**
- `production/fast-safe-release-policy.json`
- `scripts/fast-safe-release-lib.ps1`
- `tests/fast-safe-release.tests.ps1`
- `tests/fast-safe-release-integration.tests.ps1`

**Modify**
- `scripts/feature-handoff-lib.ps1`
- `scripts/feature-handoff.ps1`
- `scripts/install-feature-handoff.ps1`
- `scripts/feature-handoff-status.ps1`
- `scripts/classify-build-scope.sh`
- `scripts/ci-controller-v3.ps1`
- `scripts/production-agent.ps1`
- `tests/feature-handoff.tests.ps1`
- `tests/feature-handoff-auto-trigger.tests.ps1`
- `tests/test-classify-build-scope.sh`
- `tests/production-agent.tests.ps1`
- `tests/rebuild-dispatch-ack.tests.ps1`
- `.github/workflows/arthur-fast-preflight.yml`
- `.github/workflows/arthur-update-v3.yml`
- `.github/workflows/arthur-fast-candidate.yml`
- `.github/workflows/production-agent-deploy.yml`
- `AGENTS.md`
- `knowledge/PROJECT-STATE.md`

---

### Task 1: Machine policy and monotonic release state

**Files:**
- Create: `production/fast-safe-release-policy.json`
- Create: `scripts/fast-safe-release-lib.ps1`
- Create: `tests/fast-safe-release.tests.ps1`
- Modify: `scripts/feature-handoff-lib.ps1`

**Interfaces:**
- `Get-FastSafeReleasePolicy`
- `New-ReleaseTaskState`
- `ConvertTo-ReleaseTaskStateV2`
- `Assert-ReleaseStageTransition`
- `Add-ReleaseInvalidation`
- `Test-CheckpointValid`
- `Set-ReleaseProgress`

- [ ] **Step 1: Write failing tests**

Create `tests/fast-safe-release.tests.ps1` with assertions that:

```powershell
$policy = Get-FastSafeReleasePolicy
Assert-Equal $policy.success_terminal_state 'PRODUCTION_RELEASED' 'terminal state is fixed'
Assert-Equal $policy.recovery_law 'REUSE_RECONCILE_REPAIR_CONTINUE' 'recovery law is fixed'
Assert-True (-not $policy.allow_new_production_stages) 'new production stages are denied by default'

$state = New-ReleaseTaskState -ReleaseTaskId 'arthur:adh-quickstart:accepted-c4cadd6e' -DeviceId 'jdcloud_re-ss-01' -CurrentStage 'SOURCE_FROZEN'
Assert-Equal $state.schema_version 2 'release state schema v2'
Assert-Equal $state.terminal_state 'ACTIVE' 'new task remains active'

Assert-Throws {
    Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED'
} 'RELEASE_STAGE_REGRESSION_WITHOUT_INVALIDATION'
```

Add a schema-v1 Feature Handoff fixture and verify migration preserves `feature_id`, accepted source identity, dispatched run ID, and current stage.

- [ ] **Step 2: Verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

Expected: FAIL because the policy and helpers do not exist.

- [ ] **Step 3: Implement minimum policy/state code**

Create `production/fast-safe-release-policy.json` with policy version `1.0.0`, `success_terminal_state=PRODUCTION_RELEASED`, `recovery_law=REUSE_RECONCILE_REPAIR_CONTINUE`, the current RELEASE-FIRST stage allowlist, five impact classes, and circuit-breaker retry limit `2`.

Implement atomic state persistence and explicit invalidation records in `scripts/fast-safe-release-lib.ps1`; wire schema migration through `scripts/feature-handoff-lib.ps1`.

- [ ] **Step 4: Verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add production/fast-safe-release-policy.json scripts/fast-safe-release-lib.ps1 scripts/feature-handoff-lib.ps1 tests/fast-safe-release.tests.ps1
git commit -m "feat: add fast safe release state contract"
```

---

### Task 2: Minimum impact classification

**Files:**
- Modify: `scripts/classify-build-scope.sh`
- Modify: `tests/test-classify-build-scope.sh`
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`

**Interfaces:**
- Shell fields: `RELEASE_IMPACT_CLASS`, `MINIMUM_INVALIDATION`, `FIRMWARE_BUILD_REQUIRED`
- PowerShell: `Get-MinimumInvalidationForImpact`

- [ ] **Step 1: Write failing path-classification tests**

Require these exact mappings:

```text
HANDOFF.md                                      DOC_ONLY
knowledge/PROJECT-STATE.md                     DOC_ONLY
scripts/feature-handoff-status.ps1             CONTROL_PLANE_ONLY
scripts/ci-controller-v3.ps1                   CONTROL_PLANE_ONLY
production/accepted-preview/*.json             PREVIEW_BYTES
files/etc/config/*                             FIRMWARE_INPUT
config/arthur.config                           FIRMWARE_INPUT
config/required-plugins.txt                    FIRMWARE_INPUT
production/known-good.json                     DEVICE_WRITE_POLICY
```

A diff containing only DOC/CONTROL paths must return `FIRMWARE_BUILD_REQUIRED=false`.

- [ ] **Step 2: Verify RED**

```bash
./tests/test-classify-build-scope.sh
```

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

- [ ] **Step 3: Implement without adding a Gate**

Extend the existing classifier and preserve legacy outputs used by current workflows. Aggregate only the minimum invalidation scope required by the changed paths.

- [ ] **Step 4: Verify GREEN**

Run both commands from Step 2 and `./scripts/verify-project.sh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/classify-build-scope.sh tests/test-classify-build-scope.sh scripts/fast-safe-release-lib.ps1 tests/fast-safe-release.tests.ps1
git commit -m "feat: classify minimum release invalidation scope"
```

---

### Task 3: Preview fingerprint and checkpoint reuse

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- `Get-AcceptedPreviewFingerprint`
- `Get-PreviewReuseDecision`
- Decisions: `REUSE_PREVIEW_ACCEPTED`, `RESTORE_DRIFTED_PREVIEW_FILES`, `INVALIDATE_PREVIEW`

- [ ] **Step 1: Write failing reuse tests**

Use a two-file accepted-preview fixture. Prove changing HANDOFF text does not change the preview fingerprint. Prove matching device hashes returns `REUSE_PREVIEW_ACCEPTED`. Prove one mismatched file returns `RESTORE_DRIFTED_PREVIEW_FILES` with exactly one target path.

Also assert same fingerprint forbids source rediscovery, repeated Reuse Gate for the already accepted source, bundle reconstruction, and complete preview deployment.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

- [ ] **Step 3: Implement canonical preview fingerprint and reconcile-only recovery**

Fingerprint sorted tuples of feature ID, accepted source SHA, accepted diff SHA256, manifest SHA256, remote path, file SHA256, mode, and preview policy identity. Exclude docs, HANDOFF, runtime timestamps, PR metadata, and control-plane state.

`feature-handoff.ps1 -Mode Resume` must call `Get-PreviewReuseDecision` before any preview action.

- [ ] **Step 4: Verify GREEN**

Run Step 2 plus:

```bash
./tests/test-live-preview-contract.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 tests/fast-safe-release.tests.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: reuse accepted preview checkpoints"
```

---

### Task 4: Build fingerprint, run reuse, and Candidate quarantine

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/ci-controller-v3.ps1`
- Modify: `scripts/production-agent.ps1`
- Modify: `.github/workflows/arthur-update-v3.yml`
- Modify: `.github/workflows/arthur-fast-candidate.yml`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `tests/production-agent.tests.ps1`
- Modify: `tests/rebuild-dispatch-ack.tests.ps1`

**Interfaces:**
- `Get-BuildFingerprint`
- `Get-BuildReuseDecision`
- `Write-CandidateQuarantineRecord`
- `Get-CandidateQuarantineRecord`
- Decisions: `WATCH_EXISTING_RUN`, `REUSE_ARTIFACT`, `REVALIDATE_QUARANTINE_CANDIDATE`, `START_NEW_CANDIDATE`

- [ ] **Step 1: Write failing build-reuse tests**

Prove identical firmware inputs plus changed HANDOFF/controller text produce the same build fingerprint.

Use run/artifact fixtures:

```powershell
$running = Get-BuildReuseDecision -BuildFingerprint ('a' * 64) -Runs @(@{ id=123; fingerprint=('a' * 64); status='in_progress'; conclusion='' }) -Artifacts @()
Assert-Equal $running.action 'WATCH_EXISTING_RUN' 'identical running Candidate is watched'

$success = Get-BuildReuseDecision -BuildFingerprint ('a' * 64) -Runs @() -Artifacts @(@{ fingerprint=('a' * 64); sha256=('b' * 64); immutable=$true; acceptance='PASS' })
Assert-Equal $success.action 'REUSE_ARTIFACT' 'identical successful Candidate is reused'

$controlFail = Get-BuildReuseDecision -BuildFingerprint ('a' * 64) -Runs @() -Artifacts @(@{ fingerprint=('a' * 64); sha256=('c' * 64); immutable=$true; acceptance='CONTROL_ONLY_FAIL' })
Assert-Equal $controlFail.action 'REVALIDATE_QUARANTINE_CANDIDATE' 'control-only failure reuses Candidate bytes'
```

Change one `files/` overlay byte and assert exactly one `START_NEW_CANDIDATE` decision.

- [ ] **Step 2: Verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/production-agent.tests.ps1
pwsh -NoProfile -File ./tests/rebuild-dispatch-ack.tests.ps1
```

- [ ] **Step 3: Implement fingerprint and immutable quarantine metadata**

Fingerprint target/profile, source/feed/toolchain locks, `config/arthur.config`, `config/required-plugins.txt`, `files/` overlay, firmware-affecting patches/scripts, package/config/theme inputs. Exclude docs/HANDOFF/runtime/control-plane-only inputs.

Persist Candidate metadata immediately after image + local SHA256/manifest exist and before later acceptance can fail. Both `arthur-update-v3.yml` and `arthur-fast-candidate.yml` must emit/read the same build fingerprint metadata; do not create a new workflow.

`ci-controller-v3.ps1` must call `Get-BuildReuseDecision` before dispatching a build.

- [ ] **Step 4: Verify GREEN**

Run Step 2 plus repository workflow/static validation.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/ci-controller-v3.ps1 scripts/production-agent.ps1 tests/fast-safe-release.tests.ps1 tests/production-agent.tests.ps1 tests/rebuild-dispatch-ack.tests.ps1 .github/workflows/arthur-update-v3.yml .github/workflows/arthur-fast-candidate.yml
git commit -m "feat: reuse builds and quarantine Candidates"
```

---

### Task 5: Auto-continue recoverable failures and circuit breaker

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `scripts/ci-controller-v3.ps1`
- Modify: `scripts/production-agent.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `tests/feature-handoff-auto-trigger.tests.ps1`
- Modify: `tests/production-agent.tests.ps1`

**Interfaces:**
- `Get-FailureClass`
- `Get-FailureFingerprint`
- `Test-NextActionExecutable`
- `Register-RecoveryAttempt`
- `Get-RecoveryDecision`
- Failure classes: `FIRMWARE_INVALIDATING`, `CONTROL_OR_ACCEPTANCE_ONLY`, `DEVICE_SAFETY_AMBIGUOUS`, `TRANSIENT_EXECUTOR_LOSS`

- [ ] **Step 1: Write failing continuation tests**

Prove controller/report/parser failures after Candidate creation are `CONTROL_OR_ACCEPTANCE_ONLY` and yield `REVALIDATE_QUARANTINE_CANDIDATE`.

Prove `WATCH_EXISTING_RUN:123`, `READ_DIAGNOSTICS:123`, and `RESTORE_DRIFTED_PREVIEW_FILES` are executable actions and cannot set terminal state to COMPLETE/BLOCKED.

Prove two identical failure fingerprints with unchanged `last_progress_marker` trip `CIRCUIT_BREAKER` instead of repeating the same action a third time.

- [ ] **Step 2: Verify RED**

Run the three PowerShell suites listed in Step 1 files.

- [ ] **Step 3: Implement bounded auto-continuation**

Build failure fingerprint from current stage + first causal error + relevant input fingerprint + proposed action. Retry limit is `2` from policy. Only a genuine device/write ambiguity with no approved recovery path may become `SAFETY_BLOCKED`.

- [ ] **Step 4: Verify GREEN**

Run the same suites.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/feature-handoff.ps1 scripts/ci-controller-v3.ps1 scripts/production-agent.ps1 tests/fast-safe-release.tests.ps1 tests/feature-handoff-auto-trigger.tests.ps1 tests/production-agent.tests.ps1
git commit -m "feat: auto-continue recoverable release failures"
```

---

### Task 6: Session-independent executor recovery

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `scripts/install-feature-handoff.ps1`
- Modify: `scripts/feature-handoff-status.ps1`
- Modify: `.github/workflows/production-agent-deploy.yml`
- Modify: `tests/feature-handoff.tests.ps1`
- Modify: `tests/feature-handoff-auto-trigger.tests.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`

**Interfaces:**
- Executor fields: `executor_id`, `executor_state`, `heartbeat_at`, `current_action`, `action_started_at`
- Executor states: `RUNNING`, `LOST`, `RECOVERING`

- [ ] **Step 1: Write failing executor-loss tests**

Persist state with run `123` in progress, mark executor LOST, reload state in a fresh process, and assert `WATCH_EXISTING_RUN:123` instead of new dispatch.

Persist a successful quarantined Candidate with LOST executor and assert `REUSE_ARTIFACT`.

Persist `flash_state=WAIT_DEVICE` with LOST executor and assert `RECONCILE_REAL_DEVICE`; any new build/flash dispatch must throw.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff-auto-trigger.tests.ps1
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

- [ ] **Step 3: Implement using the existing Scheduled Task/runtime**

Do not create a new Supervisor. `install-feature-handoff.ps1` keeps the existing current-user recovery task; `feature-handoff.ps1 -Mode Resume` marks stale executors LOST, creates a fresh executor identity, reconciles live evidence, and continues the safe action.

- [ ] **Step 4: Verify GREEN**

Run Step 2 and existing `production-agent-deploy.yml` static/parser checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 scripts/install-feature-handoff.ps1 scripts/feature-handoff-status.ps1 tests/feature-handoff.tests.ps1 tests/feature-handoff-auto-trigger.tests.ps1 tests/fast-safe-release.tests.ps1 .github/workflows/production-agent-deploy.yml
git commit -m "feat: resume release after executor loss"
```

---

### Task 7: Flash-chain reconciliation

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/production-agent.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `tests/production-agent.tests.ps1`

**Interfaces:**
- `Get-WriteChainRecoveryDecision`
- Decisions: `CONTINUE_PREFLASH`, `RECONCILE_FLASH_STARTED`, `WAIT_EXISTING_DEVICE_RETURN`, `RUN_EXISTING_REAL_DEVICE_VERIFY`, `SAFETY_BLOCKED`

- [ ] **Step 1: Write failing write-chain tests**

```powershell
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'FLASH_STARTED').action 'RECONCILE_FLASH_STARTED' 'never blindly flash again'
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'WAIT_DEVICE').action 'WAIT_EXISTING_DEVICE_RETURN' 'continue existing write chain'
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'REAL_DEVICE_VERIFY').action 'RUN_EXISTING_REAL_DEVICE_VERIFY' 'resume post-flash verification'
```

All three states must reject `START_NEW_CANDIDATE` and `START_NEW_FLASH`.

- [ ] **Step 2: Verify RED**

Run fast-safe and Production Agent tests.

- [ ] **Step 3: Implement persisted write-boundary reconciliation**

Persist flash-state transitions before and after existing write boundaries and always bind recovery to the same Candidate SHA256/run identity.

- [ ] **Step 4: Verify GREEN**

Run the same suites.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/production-agent.ps1 tests/fast-safe-release.tests.ps1 tests/production-agent.tests.ps1
git commit -m "fix: reconcile flash chain on recovery"
```

---

### Task 8: Anti-expansion, integrated session-loss regression, and activation

**Files:**
- Create: `tests/fast-safe-release-integration.tests.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `.github/workflows/arthur-fast-preflight.yml`
- Modify: `AGENTS.md`
- Modify: `knowledge/PROJECT-STATE.md`
- Modify: `production/fast-safe-release-policy.json`

**Interfaces:**
- CI/static anti-expansion check reads the policy stage allowlist and existing workflow/controller ownership declarations.
- Integration test uses only fixtures; it must never call real sysupgrade or mutate a real router.

- [ ] **Step 1: Write failing anti-expansion tests**

The current stage model must pass. A fixture containing `NEW_PRODUCTION_GATE` must fail with `UNAPPROVED_PRODUCTION_STAGE`. A fixture that declares a fourth production workflow owner must fail with `UNAPPROVED_WORKFLOW_OWNER`.

- [ ] **Step 2: Write failing controlled session-loss integration test**

Simulate:

```text
PREVIEW_ACCEPTED + SOURCE_FROZEN verified
build fingerprint F
run 123 in_progress
executor LOST
=> WATCH_EXISTING_RUN 123

run 123 success + immutable Candidate A
executor LOST
=> REUSE_ARTIFACT A

flash state WAIT_DEVICE
executor LOST
=> WAIT_EXISTING_DEVICE_RETURN

REAL_DEVICE_VERIFY PASS
=> PRODUCTION_RELEASED
```

Counters must finish at:

```text
duplicate_preview_deploy=0
duplicate_build_dispatch=0
duplicate_flash=0
```

- [ ] **Step 3: Verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/fast-safe-release-integration.tests.ps1
```

- [ ] **Step 4: Wire existing executors through the shared contract**

Use only Tasks 1–7 helpers; do not create a test-only orchestration path. Add both tests to `.github/workflows/arthur-fast-preflight.yml`. Update `AGENTS.md` to point to `production/fast-safe-release-policy.json`; update `knowledge/PROJECT-STATE.md` with policy version only.

- [ ] **Step 5: Run full relevant verification**

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/fast-safe-release-integration.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff-auto-trigger.tests.ps1
pwsh -NoProfile -File ./tests/production-agent.tests.ps1
pwsh -NoProfile -File ./tests/rebuild-dispatch-ack.tests.ps1
```

```bash
./tests/test-classify-build-scope.sh
./tests/test-live-preview-contract.sh
./scripts/verify-project.sh
```

Expected: all PASS; the simulated release reaches `PRODUCTION_RELEASED` with zero duplicate expensive actions.

- [ ] **Step 6: Commit**

```bash
git add tests/fast-safe-release.tests.ps1 tests/fast-safe-release-integration.tests.ps1 .github/workflows/arthur-fast-preflight.yml AGENTS.md knowledge/PROJECT-STATE.md production/fast-safe-release-policy.json
git commit -m "test: enforce fast safe unattended release contract"
```

- [ ] **Step 7: Activate without restarting current work**

After implementation PR CI is green, Resume Gate must adopt any active run/artifact/flash state already present. Activation is accepted only if GitHub run count, Candidate identities, and durable flash state prove no duplicate preview/build/flash was created solely by activation.

- [ ] **Step 8: Real acceptance**

Complete one real Arthur release through the existing production path. Final evidence must include:

```text
FAST_SAFE_RELEASE_POLICY=1.0.0
DUPLICATE_PREVIEW=0
DUPLICATE_BUILD=0
DUPLICATE_FLASH=0
SESSION_LOSS_AUTO_RESUME=PASS
PRODUCTION_RELEASED=true
```
