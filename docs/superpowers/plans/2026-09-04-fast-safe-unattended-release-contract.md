# Fast Safe Unattended Release Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce one machine-level execution contract so Arthur and future XinZhaoWrt firmware work reaches `PRODUCTION_RELEASED` as quickly as possible without repeating valid preview/build/flash work and without weakening device, artifact, rollback, or acceptance safety.

**Architecture:** Extend the existing Feature Handoff/runtime, v3 controller, Production Agent, and build-scope classifier rather than adding a new production stage or workflow owner. Add a machine-readable release policy plus shared fingerprint/invalidation/recovery primitives; existing executors consume those primitives to implement `REUSE → RECONCILE → REPAIR → CONTINUE`, with monotonic verified checkpoints, Candidate quarantine reuse, executable-next-action continuation, and session-independent recovery.

**Tech Stack:** PowerShell 7/Windows PowerShell compatibility where existing runtime requires it, Bash, Python 3 only where already used by repository tests/workflows, Git/GitHub CLI, GitHub Actions, Windows Scheduled Tasks, JSON durable state.

**Spec:** `docs/superpowers/specs/2026-09-04-fast-safe-unattended-release-contract-design.md`

## Global Constraints

- The only successful terminal state is `PRODUCTION_RELEASED`.
- Preserve the existing frozen production stage order; do not add, rename, replace, or reorder production Gates/stages.
- No new Supervisor/workflow owner is introduced. Existing Feature Handoff/runtime owns durable continuation; v3 Controller and Production Agent retain their existing build/flash/release responsibilities.
- Recovery law is `REUSE → RECONCILE → REPAIR → CONTINUE`; restart from an earlier verified stage requires explicit invalidation evidence.
- Pure documentation/HANDOFF/control-plane changes must not invalidate firmware preview/build bytes.
- Same accepted preview fingerprint must reuse accepted preview evidence; same build fingerprint must reuse an active run or immutable Candidate artifact.
- After Candidate bytes + SHA256/manifest exist, acceptance/control-plane failures must reuse the quarantined Candidate unless firmware-invalidating evidence exists.
- `FLASH_STARTED`, `WAIT_DEVICE`, and `REAL_DEVICE_VERIFY` recovery must reconcile the existing write chain and must never start a second flash chain.
- A deterministic, safe `next_action` is not a legal terminal condition.
- No safety rule for device identity, artifact hash, rollback path, mandatory plugins, config/theme checks, AUTO_FLASH_SAFETY_GATE, sysupgrade parameters, or REAL_DEVICE_VERIFY may be weakened.
- Current active release work must not be cancelled, restarted, or redispatched merely to activate this contract; attach only by adopting existing durable evidence/run IDs.

---

## File Structure

- Create `production/fast-safe-release-policy.json` — machine-readable permanent policy/version, frozen production-stage names, impact classes, retry/circuit-breaker defaults, and anti-expansion allowlist.
- Create `scripts/fast-safe-release-lib.ps1` — pure/shared release-state, fingerprint, invalidation, reuse-decision, progress, circuit-breaker, and terminal-state helpers. No top-level orchestration.
- Create `tests/fast-safe-release.tests.ps1` — behavioral contract tests for state monotonicity, preview/build reuse, invalidation scope, executable-next-action continuation, flash-chain reconciliation, and circuit breaker.
- Modify `scripts/feature-handoff-lib.ps1` — schema-v1→v2 migration hooks and durable release-task fields; delegate shared decisions to `fast-safe-release-lib.ps1`.
- Modify `scripts/feature-handoff.ps1` — consume reuse/reconcile decisions, refuse illegal stage regression, auto-execute deterministic next_action, and recover LOST executor state.
- Modify `scripts/install-feature-handoff.ps1` — ensure scheduled recovery invokes the durable release task even after executor/session exit, without creating a second orchestration owner.
- Modify `scripts/feature-handoff-status.ps1` — expose release_task_id, fingerprints, active run/artifact, invalidations, progress marker, failure fingerprint, and terminal state.
- Modify `scripts/classify-build-scope.sh` — emit `DOC_ONLY`, `CONTROL_PLANE_ONLY`, `PREVIEW_BYTES`, `FIRMWARE_INPUT`, or `DEVICE_WRITE_POLICY` and map those classes to minimum invalidation scope.
- Modify `tests/test-classify-build-scope.sh` — enforce no firmware build for DOC/CONTROL-only changes and correct classification of firmware inputs.
- Modify `scripts/ci-controller-v3.ps1` — before dispatch/rebuild, consult build fingerprint and durable run/artifact evidence; return WATCH/REUSE/REVALIDATE instead of redispatching identical work.
- Modify `production-agent.ps1` or the repository’s current Production Agent entry script at its existing path — adopt existing run/artifact/flash state, quarantine Candidate identity before later acceptance, and refuse duplicate build/flash chains.
- Modify relevant Production Agent tests at their existing path — verify quarantine reuse and flash reconciliation.
- Modify `.github/workflows/arthur-fast-preflight.yml` — run the new contract tests and PowerShell parse checks only; no new production stage.
- Modify existing build workflow(s) only where necessary to persist/read build fingerprint and immutable Candidate quarantine metadata; do not add a new workflow.
- Modify `AGENTS.md` — replace prose-only enforcement with a pointer to `production/fast-safe-release-policy.json` and the shared machine contract while retaining the human-readable permanent objective.
- Modify `knowledge/PROJECT-STATE.md` — record active contract version and migration status only.

---

### Task 1: Machine policy and monotonic durable release state

**Files:**
- Create: `production/fast-safe-release-policy.json`
- Create: `scripts/fast-safe-release-lib.ps1`
- Create: `tests/fast-safe-release.tests.ps1`
- Modify: `scripts/feature-handoff-lib.ps1`

**Interfaces:**
- Produces `Get-FastSafeReleasePolicy`, `New-ReleaseTaskState`, `ConvertTo-ReleaseTaskStateV2`, `Save-ReleaseTaskState`, `Assert-ReleaseStageTransition`, `Add-ReleaseInvalidation`, `Test-CheckpointValid`, `Set-ReleaseProgress`.
- Durable fields include `release_task_id`, `current_stage`, `last_verified_stage`, `terminal_state`, `accepted_preview_fingerprint`, `build_fingerprint`, `active_run_id`, `artifact_sha256`, `artifact_identity`, `flash_state`, `next_action`, `invalidations`, `last_progress_at`, `last_progress_marker`.

- [ ] **Step 1: Write failing state/policy tests**

Add tests that load `production/fast-safe-release-policy.json` and assert the frozen production order contains the existing stage names only, the terminal success state is exactly `PRODUCTION_RELEASED`, and the default recovery law is exactly `REUSE_RECONCILE_REPAIR_CONTINUE`.

Add PowerShell tests:

```powershell
$state = New-ReleaseTaskState `
    -ReleaseTaskId 'arthur:adh-quickstart:abc123' `
    -DeviceId 'jdcloud_re-ss-01' `
    -CurrentStage 'SOURCE_FROZEN'

Assert-Equal $state.schema_version 2 'new release state uses schema v2'
Assert-Equal $state.terminal_state 'ACTIVE' 'new release is active'
Assert-Equal $state.last_verified_stage 'SOURCE_FROZEN' 'verified checkpoint is retained'

Assert-Throws {
    Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED'
} 'RELEASE_STAGE_REGRESSION_WITHOUT_INVALIDATION'

Add-ReleaseInvalidation -State $state `
    -Checkpoint 'SOURCE_FROZEN' `
    -Reason 'accepted preview bytes changed' `
    -OldFingerprint ('a' * 64) `
    -NewFingerprint ('b' * 64) `
    -MinimumRepeatStage 'PREVIEW_ACCEPTED'

Assert-DoesNotThrow {
    Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED'
}
```

Add migration tests that load a representative Feature Handoff schema-v1 state and verify it upgrades in memory without losing `feature_id`, accepted source identity, dispatched run ID, or current stage.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

Expected: FAIL because the policy and shared release-state helpers do not exist.

- [ ] **Step 3: Implement machine policy and state helpers**

Create `production/fast-safe-release-policy.json` with:

```json
{
  "schema_version": 1,
  "policy_id": "fast-safe-release",
  "policy_version": "1.0.0",
  "success_terminal_state": "PRODUCTION_RELEASED",
  "recovery_law": "REUSE_RECONCILE_REPAIR_CONTINUE",
  "production_stage_model": "RELEASE_FIRST_V3",
  "allow_new_production_stages": false,
  "impact_classes": [
    "DOC_ONLY",
    "CONTROL_PLANE_ONLY",
    "PREVIEW_BYTES",
    "FIRMWARE_INPUT",
    "DEVICE_WRITE_POLICY"
  ],
  "circuit_breaker": {
    "same_failure_without_progress_max_attempts": 2
  }
}
```

Implement atomic JSON persistence using `.tmp` + replace/move semantics already used by Feature Handoff. `Assert-ReleaseStageTransition` must reject backward transitions unless the durable invalidation list contains an applicable record.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS for the new release-state tests and no regression in existing Feature Handoff tests.

- [ ] **Step 5: Commit**

```bash
git add production/fast-safe-release-policy.json scripts/fast-safe-release-lib.ps1 scripts/feature-handoff-lib.ps1 tests/fast-safe-release.tests.ps1
git commit -m "feat: add fast safe release state contract"
```

---

### Task 2: Unified impact classification and minimum invalidation scope

**Files:**
- Modify: `scripts/classify-build-scope.sh`
- Modify: `tests/test-classify-build-scope.sh`
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`

**Interfaces:**
- Produces shell output `RELEASE_IMPACT_CLASS=<class>` and `MINIMUM_INVALIDATION=<scope>`.
- Produces PowerShell `Get-MinimumInvalidationForImpact -ImpactClass <string>`.

- [ ] **Step 1: Add failing impact tests**

Add shell fixtures asserting:

```text
HANDOFF.md                         -> DOC_ONLY
knowledge/*.md                    -> DOC_ONLY
scripts/feature-handoff-status.ps1 -> CONTROL_PLANE_ONLY
scripts/ci-controller-v3.ps1      -> CONTROL_PLANE_ONLY unless a test fixture marks a firmware-input section change
production/accepted-preview/*.json -> PREVIEW_BYTES
files/etc/config/...              -> FIRMWARE_INPUT
config/arthur.config              -> FIRMWARE_INPUT
config/required-plugins.txt       -> FIRMWARE_INPUT
production/known-good.json        -> DEVICE_WRITE_POLICY
```

Assert a DOC/CONTROL-only diff returns `FIRMWARE_BUILD_REQUIRED=false`.

Add PowerShell assertions:

```powershell
Assert-Equal (Get-MinimumInvalidationForImpact 'DOC_ONLY') 'NONE' 'docs invalidate nothing'
Assert-Equal (Get-MinimumInvalidationForImpact 'CONTROL_PLANE_ONLY') 'CONTROL_EVIDENCE_ONLY' 'controller-only changes keep Candidate bytes'
Assert-Equal (Get-MinimumInvalidationForImpact 'PREVIEW_BYTES') 'PREVIEW_AND_DOWNSTREAM' 'preview bytes invalidate preview and downstream image when frozen'
Assert-Equal (Get-MinimumInvalidationForImpact 'FIRMWARE_INPUT') 'BUILD_AND_DOWNSTREAM' 'firmware input invalidates build'
Assert-Equal (Get-MinimumInvalidationForImpact 'DEVICE_WRITE_POLICY') 'PREFLASH_AND_DOWNSTREAM' 'write policy forces fresh preflash safety'
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
./tests/test-classify-build-scope.sh
```

and:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

Expected: FAIL on the new classification contract.

- [ ] **Step 3: Implement classification without adding a Gate**

Extend the existing classifier output while preserving any legacy fields consumed by current workflows. Map changed paths to the five impact classes and aggregate to the highest required invalidation scope.

- [ ] **Step 4: Run tests and verify GREEN**

Run both test commands from Step 2 plus the repository’s existing static verifier for build-scope classification.

Expected: PASS; DOC/CONTROL-only fixtures explicitly prove no firmware build dispatch is requested.

- [ ] **Step 5: Commit**

```bash
git add scripts/classify-build-scope.sh tests/test-classify-build-scope.sh scripts/fast-safe-release-lib.ps1 tests/fast-safe-release.tests.ps1
git commit -m "feat: classify minimum release invalidation scope"
```

---

### Task 3: Accepted-preview fingerprint and checkpoint reuse

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Produces `Get-AcceptedPreviewFingerprint`, `Compare-AcceptedPreviewToDeviceState`, `Get-PreviewReuseDecision`.
- Decisions: `REUSE_PREVIEW_ACCEPTED`, `RESTORE_DRIFTED_PREVIEW_FILES`, `INVALIDATE_PREVIEW`.

- [ ] **Step 1: Write failing preview-reuse tests**

Build a temporary accepted-preview record with two frozen files and stable hashes. Assert:

```powershell
$fingerprint1 = Get-AcceptedPreviewFingerprint -AcceptedRecord $record
$fingerprint2 = Get-AcceptedPreviewFingerprint -AcceptedRecord $recordCloneWithDifferentHandoffText
Assert-Equal $fingerprint1 $fingerprint2 'HANDOFF text does not alter accepted preview fingerprint'

$decision = Get-PreviewReuseDecision -AcceptedRecord $record -DeviceHashes @{
    '/usr/lib/lua/luci/controller/AdGuardHome.lua' = $record.frozen_files[0].sha256
    '/etc/init.d/AdGuardHome' = $record.frozen_files[1].sha256
}
Assert-Equal $decision.action 'REUSE_PREVIEW_ACCEPTED' 'matching device hashes skip preview deploy'

$decision = Get-PreviewReuseDecision -AcceptedRecord $record -DeviceHashes @{
    '/usr/lib/lua/luci/controller/AdGuardHome.lua' = ('0' * 64)
    '/etc/init.d/AdGuardHome' = $record.frozen_files[1].sha256
}
Assert-Equal $decision.action 'RESTORE_DRIFTED_PREVIEW_FILES' 'only drifted files are restored'
Assert-Equal $decision.paths.Count 1 'one drifted path does not rebuild/redeploy the full bundle'
```

Add a contract assertion that same fingerprint may not call source discovery/Reuse Gate/bundle reconstruction again.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL on missing fingerprint/reuse functions.

- [ ] **Step 3: Implement normalized preview fingerprint and reuse decision**

Hash canonical UTF-8 JSON made from sorted tuples of feature/source/diff/manifest/file-path/file-hash/mode/policy identity. Exclude HANDOFF, docs, controller state, runtime timestamps, and PR metadata.

Modify Feature Handoff Resume so an existing accepted record first resolves through `Get-PreviewReuseDecision`. A matching record advances/reuses the verified checkpoint; a drifted subset restores only listed files from frozen bytes and runs only existing affected acceptance checks.

- [ ] **Step 4: Run tests and verify GREEN**

Run the two test commands from Step 2 plus `tests/test-live-preview-contract.sh`.

Expected: PASS and no full preview redeploy for the matching-fingerprint fixture.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 tests/fast-safe-release.tests.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: reuse accepted Arthur preview checkpoints"
```

---

### Task 4: Build fingerprint, active-run reuse, and Candidate quarantine

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/ci-controller-v3.ps1`
- Modify: current Production Agent entry script at its repository path
- Modify: existing Candidate/build workflow(s) that already create Arthur artifacts
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: existing controller/Production Agent tests

**Interfaces:**
- Produces `Get-BuildFingerprint`, `Get-BuildReuseDecision`, `Write-CandidateQuarantineRecord`, `Get-CandidateQuarantineRecord`.
- Build decisions: `WATCH_EXISTING_RUN`, `REUSE_ARTIFACT`, `REVALIDATE_QUARANTINE_CANDIDATE`, `START_NEW_CANDIDATE`.

- [ ] **Step 1: Add failing build-reuse tests**

Create fixtures with identical firmware inputs but changed HANDOFF/controller text and assert identical fingerprints.

Assert:

```powershell
$decision = Get-BuildReuseDecision -BuildFingerprint $fp -Runs @(
    @{ id = 123; fingerprint = $fp; status = 'in_progress'; conclusion = '' }
) -Artifacts @()
Assert-Equal $decision.action 'WATCH_EXISTING_RUN' 'running identical Candidate is watched'
Assert-Equal $decision.run_id 123 'existing run id is retained'

$decision = Get-BuildReuseDecision -BuildFingerprint $fp -Runs @() -Artifacts @(
    @{ fingerprint = $fp; sha256 = ('a' * 64); immutable = $true; acceptance = 'PASS' }
)
Assert-Equal $decision.action 'REUSE_ARTIFACT' 'successful identical Candidate is reused'

$decision = Get-BuildReuseDecision -BuildFingerprint $fp -Runs @() -Artifacts @(
    @{ fingerprint = $fp; sha256 = ('b' * 64); immutable = $true; acceptance = 'CONTROL_ONLY_FAIL' }
)
Assert-Equal $decision.action 'REVALIDATE_QUARANTINE_CANDIDATE' 'acceptance-only failure does not rebuild Candidate bytes'
```

Add a fixture changing one `files/` overlay byte and assert the fingerprint changes and exactly one `START_NEW_CANDIDATE` decision is produced.

- [ ] **Step 2: Run tests and verify RED**

Run the new contract tests plus the existing v3 controller and Production Agent test suites.

Expected: FAIL on missing build-reuse/quarantine behavior.

- [ ] **Step 3: Implement fingerprint and quarantine metadata**

Build fingerprint canonical inputs must include target/profile/source/feed/toolchain/config/required-plugin/files-overlay/build-patch identities and exclude docs/HANDOFF/control-plane-only data.

Immediately after image + SHA256/manifest creation, persist quarantine metadata containing at minimum:

```json
{
  "schema_version": 1,
  "build_fingerprint": "<64 hex>",
  "run_id": 123,
  "source_sha": "<40 hex>",
  "artifact_name": "...",
  "artifact_sha256": "<64 hex>",
  "target": "qualcommax/ipq60xx",
  "profile": "jdcloud_re-ss-01",
  "acceptance_class": "PENDING"
}
```

Controller dispatch path must call `Get-BuildReuseDecision` before any new build dispatch.

- [ ] **Step 4: Run tests and verify GREEN**

Run the same test suites from Step 2 and repository static workflow validation.

Expected: PASS; controller fixtures prove no duplicate dispatch for matching fingerprint.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/ci-controller-v3.ps1 tests/fast-safe-release.tests.ps1 <production-agent-path> <production-agent-tests> <existing-build-workflow-paths>
git commit -m "feat: reuse Arthur builds and quarantine Candidates"
```

---

### Task 5: Failure classification, executable next_action continuation, and circuit breaker

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `scripts/ci-controller-v3.ps1`
- Modify: current Production Agent entry script
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: existing recovery/controller tests

**Interfaces:**
- Produces `Get-FailureClass`, `Get-FailureFingerprint`, `Test-NextActionExecutable`, `Register-RecoveryAttempt`, `Get-RecoveryDecision`.
- Failure classes: `FIRMWARE_INVALIDATING`, `CONTROL_OR_ACCEPTANCE_ONLY`, `DEVICE_SAFETY_AMBIGUOUS`, `TRANSIENT_EXECUTOR_LOSS`.

- [ ] **Step 1: Add failing continuation/circuit-breaker tests**

Assert a controller-path failure after Candidate quarantine yields `CONTROL_OR_ACCEPTANCE_ONLY` and the recovery action `REVALIDATE_QUARANTINE_CANDIDATE`.

Assert a deterministic next action such as `WATCH_EXISTING_RUN:123`, `READ_DIAGNOSTICS:123`, or `RESTORE_DRIFTED_PREVIEW_FILES` returns `executable=$true` and may not set terminal state to `BLOCKED` or `COMPLETE`.

Add repeated-failure test:

```powershell
$state.last_progress_marker = 'candidate:123:acceptance-failed'
Register-RecoveryAttempt -State $state -FailureFingerprint $failureFp -Action 'RETRY_SAME_PREVIEW'
Register-RecoveryAttempt -State $state -FailureFingerprint $failureFp -Action 'RETRY_SAME_PREVIEW'
$decision = Get-RecoveryDecision -State $state -FailureFingerprint $failureFp -ProposedAction 'RETRY_SAME_PREVIEW'
Assert-Equal $decision.action 'CIRCUIT_BREAKER' 'same action cannot repeat without progress'
```

- [ ] **Step 2: Run tests and verify RED**

Run the contract and existing recovery/controller tests.

Expected: FAIL on missing classification/continuation/circuit-breaker helpers.

- [ ] **Step 3: Implement minimal failure and retry policy**

Use first causal error + current stage + relevant fingerprint + proposed action to build a stable failure fingerprint. Default same-failure/no-progress limit comes from `fast-safe-release-policy.json` and is `2`.

Feature Handoff and controller loops must continue automatically when `Test-NextActionExecutable` is true. Only `DEVICE_SAFETY_AMBIGUOUS` with no approved recovery path may transition to `SAFETY_BLOCKED`.

- [ ] **Step 4: Run tests and verify GREEN**

Run the test suites from Step 2.

Expected: PASS; repeated same-action fixtures trip the circuit breaker rather than looping.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 scripts/feature-handoff.ps1 scripts/ci-controller-v3.ps1 tests/fast-safe-release.tests.ps1 <production-agent-path> <recovery-tests>
git commit -m "feat: auto-continue recoverable release failures"
```

---

### Task 6: Session-independent executor recovery using existing Feature Handoff runtime

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `scripts/install-feature-handoff.ps1`
- Modify: `scripts/feature-handoff-status.ps1`
- Modify: `tests/feature-handoff.tests.ps1`
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: existing scheduled-task/production-agent deployment tests

**Interfaces:**
- Produces executor fields `executor_id`, `executor_state`, `heartbeat_at`, `current_action`, `action_started_at` separate from release identity.
- Produces recovery states `ACTIVE`, `LOST`, `RECOVERING`, `RUNNING`; release terminal state remains independent.

- [ ] **Step 1: Add failing executor-loss tests**

Create durable state with `active_run_id=123` and `build_fingerprint=<fp>`, mark executor heartbeat stale/LOST, and assert Resume returns `WATCH_EXISTING_RUN:123` rather than dispatching a new build.

Create state with a successful quarantined artifact and LOST executor; assert Resume returns `REUSE_ARTIFACT`.

Create state with `flash_state='WAIT_DEVICE'` and LOST executor; assert Resume returns `RECONCILE_REAL_DEVICE` and a second build/flash dispatch is rejected.

Simulate process restart by saving state, creating a new process/test invocation, and verifying the next action is derived solely from durable state + supplied live evidence fixtures.

- [ ] **Step 2: Run tests and verify RED**

Run Feature Handoff and fast-safe release tests.

Expected: FAIL because executor identity/heartbeat is not separated from release identity.

- [ ] **Step 3: Implement executor lease/heartbeat and restart continuation**

Scheduled recovery invokes existing `feature-handoff.ps1 -Mode Resume`. Resume marks stale executor `LOST`, creates a new executor identity, reconciles live evidence, and continues the machine-executable action. It must not create a second orchestration service.

- [ ] **Step 4: Run tests and verify GREEN**

Run Feature Handoff tests, fast-safe tests, and existing task-install/deploy tests.

Expected: PASS for process-loss recovery without operator `继续`.

- [ ] **Step 5: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 scripts/install-feature-handoff.ps1 scripts/feature-handoff-status.ps1 tests/feature-handoff.tests.ps1 tests/fast-safe-release.tests.ps1 <scheduled-task-tests>
git commit -m "feat: resume Arthur release after executor loss"
```

---

### Task 7: Flash-chain reconciliation and duplicate-write prevention

**Files:**
- Modify: `scripts/fast-safe-release-lib.ps1`
- Modify: current Production Agent entry script
- Modify: existing Production Agent tests
- Modify: `tests/fast-safe-release.tests.ps1`

**Interfaces:**
- Produces `Get-WriteChainRecoveryDecision`.
- Decisions: `CONTINUE_PREFLASH`, `RECONCILE_FLASH_STARTED`, `WAIT_EXISTING_DEVICE_RETURN`, `RUN_EXISTING_REAL_DEVICE_VERIFY`, `SAFETY_BLOCKED`.

- [ ] **Step 1: Add failing write-chain tests**

Assert:

```powershell
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'FLASH_STARTED').action 'RECONCILE_FLASH_STARTED' 'never blindly flash again'
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'WAIT_DEVICE').action 'WAIT_EXISTING_DEVICE_RETURN' 'wait existing write chain'
Assert-Equal (Get-WriteChainRecoveryDecision -FlashState 'REAL_DEVICE_VERIFY').action 'RUN_EXISTING_REAL_DEVICE_VERIFY' 'resume post-flash verification'
```

Add a hard test that all three states reject `START_NEW_CANDIDATE` and `START_NEW_FLASH`.

- [ ] **Step 2: Run tests and verify RED**

Run fast-safe and Production Agent tests.

Expected: FAIL on missing write-chain recovery helper.

- [ ] **Step 3: Implement write-chain reconciliation**

Production Agent must persist flash-state transitions before/after each write boundary and use the existing candidate identity/SHA. Recovery must inspect live device/build evidence before choosing the next existing-chain action.

- [ ] **Step 4: Run tests and verify GREEN**

Run the test suites from Step 2.

Expected: PASS and no duplicate write path is reachable from recovery fixtures.

- [ ] **Step 5: Commit**

```bash
git add scripts/fast-safe-release-lib.ps1 tests/fast-safe-release.tests.ps1 <production-agent-path> <production-agent-tests>
git commit -m "fix: reconcile Arthur flash chain on recovery"
```

---

### Task 8: Anti-expansion enforcement and permanent Source of Truth

**Files:**
- Modify: `tests/fast-safe-release.tests.ps1`
- Modify: `.github/workflows/arthur-fast-preflight.yml`
- Modify: `AGENTS.md`
- Modify: `knowledge/PROJECT-STATE.md`
- Modify: `production/fast-safe-release-policy.json`

**Interfaces:**
- Contract test reads current workflow/controller files and the policy allowlist; any unapproved production stage/Gate/workflow-owner addition fails.

- [ ] **Step 1: Add failing anti-expansion tests**

Test the current production stage names against the policy allowlist. Add a temporary fixture with `NEW_PRODUCTION_GATE` and assert the parser fails with `UNAPPROVED_PRODUCTION_STAGE`.

Add a test that a new workflow owner declaration outside the existing Feature Handoff/v3 Controller/Production Agent ownership model fails.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
```

Expected: FAIL until policy allowlist and parser are implemented.

- [ ] **Step 3: Implement anti-expansion parser and docs routing**

Keep anti-expansion as CI/static validation only; do not insert it into the runtime production stage order. Update `AGENTS.md` to state the permanent objective and point machine enforcement to `production/fast-safe-release-policy.json`. Update `knowledge/PROJECT-STATE.md` with active policy version and no transient run detail.

- [ ] **Step 4: Run tests and verify GREEN**

Run fast-safe tests and `arthur-fast-preflight` equivalent local checks.

Expected: PASS; unapproved-stage fixture fails as expected while the real current production model passes.

- [ ] **Step 5: Commit**

```bash
git add tests/fast-safe-release.tests.ps1 .github/workflows/arthur-fast-preflight.yml AGENTS.md knowledge/PROJECT-STATE.md production/fast-safe-release-policy.json
git commit -m "test: enforce fast safe release architecture"
```

---

### Task 9: Controlled end-to-end recovery regression without real duplicate writes

**Files:**
- Modify: `tests/fast-safe-release.tests.ps1`
- Create or modify an existing non-production recovery integration test script under `tests/`
- Modify `.github/workflows/arthur-fast-preflight.yml` only to execute the non-destructive integration test

**Interfaces:**
- Integration fixture simulates durable state + GitHub run/artifact/device evidence; it must never invoke real sysupgrade or mutate a real router.

- [ ] **Step 1: Write failing simulated session-loss scenario**

Scenario:

```text
PREVIEW_ACCEPTED verified
SOURCE_FROZEN verified
build fingerprint F
run 123 in_progress
executor lost
new executor resumes
=> WATCH_EXISTING_RUN 123

run 123 success + Candidate artifact A
executor lost again
=> REUSE_ARTIFACT A

flash state WAIT_DEVICE
executor lost again
=> WAIT_EXISTING_DEVICE_RETURN

post-flash verifier PASS
=> PRODUCTION_RELEASED
```

Assert zero duplicate preview deploy calls, zero duplicate build dispatch calls, and zero duplicate flash calls.

- [ ] **Step 2: Run test and verify RED**

Run the isolated integration test.

Expected: FAIL until all previous task interfaces are wired together.

- [ ] **Step 3: Wire existing executors through the shared contract**

Use the same helper entry points implemented in Tasks 1–7. Do not add a test-only orchestration path that production does not use.

- [ ] **Step 4: Run full relevant verification**

Run:

```powershell
pwsh -NoProfile -File ./tests/fast-safe-release.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Run:

```bash
./tests/test-classify-build-scope.sh
./tests/test-live-preview-contract.sh
```

Then run repository PowerShell parser/static contract tests and the non-destructive integration scenario.

Expected: all PASS; controlled session loss reaches simulated `PRODUCTION_RELEASED` without operator continuation and without duplicate preview/build/flash actions.

- [ ] **Step 5: Commit**

```bash
git add tests .github/workflows/arthur-fast-preflight.yml scripts production AGENTS.md knowledge/PROJECT-STATE.md
git commit -m "test: prove unattended Arthur release recovery"
```

---

### Task 10: Activation and verification against a live release checkpoint

**Files:**
- No new production stage files.
- Update durable handoff/project-state records only through existing runtime mechanisms after merge.

**Interfaces:**
- Consumes current active release state, run IDs, artifacts, accepted-preview records, and device evidence.
- Produces adoption evidence showing no redispatch/rebuild/reflash occurred solely due to contract activation.

- [ ] **Step 1: Merge only after repository CI is green**

Do not merge if the active Arthur release has an in-progress sysupgrade/write ambiguity. If a build/run is active, activation must adopt its run ID.

- [ ] **Step 2: Run Resume Gate with the new contract**

Expected output must identify the current durable release task and one of the reuse/reconcile actions, not restart an earlier stage.

- [ ] **Step 3: Verify no duplicate expensive action was created by activation**

Check GitHub runs, Candidate artifact identities, and durable flash state. Confirm activation did not create a second identical build or flash chain.

- [ ] **Step 4: Complete one real release to `PRODUCTION_RELEASED`**

Use the existing production path and all existing safety gates. The new contract only selects reuse/reconcile/repair decisions behind that path.

- [ ] **Step 5: Record contract verification**

Update `knowledge/PROJECT-STATE.md` with policy version and verified activation state; do not store transient run history as permanent policy.

- [ ] **Step 6: Commit any final non-runtime documentation/state routing changes**

```bash
git add knowledge/PROJECT-STATE.md
 git commit -m "docs: activate fast safe release contract"
```

Expected final evidence:

```text
FAST_SAFE_RELEASE_POLICY=1.0.0
DUPLICATE_PREVIEW=0
DUPLICATE_BUILD=0
DUPLICATE_FLASH=0
SESSION_LOSS_AUTO_RESUME=PASS
PRODUCTION_RELEASED=true
```
