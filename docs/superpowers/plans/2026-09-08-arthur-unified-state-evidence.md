# Arthur Unified State Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the existing Arthur Control Plane so every production Gate is backed by identity-matched durable evidence, stale evidence is invalidated automatically, and resume/next-action decisions come from one reconciled schema-v2 execution state without introducing a second orchestrator.

**Architecture:** Preserve `feature-handoff.ps1`, `ci-controller-v3.ps1`, `production-agent.ps1`, `production/resume-state.json`, and `production/firmware-events.jsonl`. Add two focused helpers: one pure state-contract module for execution identity, Gate status, requirement digests, staleness and next-action selection; one evidence-index module for small durable evidence metadata. Migrate the Control Plane to be the only Gate arbiter and make Feature Handoff/Production Agent submit observations/evidence rather than global PASS claims.

**Tech Stack:** PowerShell 7, JSON, existing shell build-scope classifier, GitHub Actions/`gh`, existing Arthur PowerShell contract tests.

**Spec:** `docs/superpowers/specs/2026-09-08-arthur-unified-state-evidence-design.md`

## Global Constraints

- Keep `PRODUCTION_RELEASED` as the only successful terminal state.
- Do not create a parallel `.runtime/current.json` controller or second production orchestrator.
- Keep numeric GitHub Actions `run_id` semantics unchanged.
- Add a stable string `execution_id` spanning one end-to-end Arthur task.
- Allowed Gate statuses are exactly `PENDING`, `RUNNING`, `PASS`, `FAIL`, `BLOCKED`, `STALE`, `SKIPPED`.
- `PASS` requires valid evidence or explicit inherited-baseline provenance.
- Requirement identity must include a durable `requirement_digest`; changed acceptance criteria invalidate historical PASS.
- Source/artifact/device identity changes invalidate only dependent Gates; unrelated frozen Wi-Fi evidence remains inheritable when change impact proves it unaffected.
- State/evidence-only commits must not request firmware builds.
- Existing operator-intent authorization remains scope-bound and must not be broadened.
- After `FLASH_STARTED`, recovery must reconcile the real device before any new write.
- No firmware build, upload, flash, or release is required merely to deploy this state-contract change.

---

### Task 1: Add the pure execution/Gate contract

**Files:**
- Create: `scripts/arthur-state-contract.ps1`
- Create: `tests/arthur-state-contract.tests.ps1`

**Interfaces:**
- Produces: `New-ArthurExecutionId`, `Get-ArthurRequirementDigest`, `New-ArthurGateRecord`, `Test-ArthurGateEvidenceMatch`, `Resolve-ArthurGateStatus`, `Get-ArthurNextRequiredGate`.
- Consumes: plain PowerShell objects only; no GitHub, SSH, filesystem mutation, or Control Plane globals.

- [ ] **Step 1: Write failing contract tests**

Create tests proving these behaviors:

```powershell
. (Join-Path $Root 'scripts\arthur-state-contract.ps1')

$id = New-ArthurExecutionId -TaskSlug 'adh-cn' -AcceptedSourceSha ('a' * 40) -Date ([datetime]'2026-09-08')
Assert-Equal $id 'arthur-adh-cn-aaaaaaa-20260908' 'execution id must be deterministic'

$d1 = Get-ArthurRequirementDigest -RequirementText 'Default language: zh_cn'
$d2 = Get-ArthurRequirementDigest -RequirementText 'Default language: zh_cn'
$d3 = Get-ArthurRequirementDigest -RequirementText 'Default language: en'
Assert-Equal $d1 $d2 'same requirement must hash identically'
Assert-True ($d1 -ne $d3) 'changed requirement must produce a different digest'

$gate = New-ArthurGateRecord -GateId 'ARTIFACT' -RequirementRef 'production/release-policy.md#Candidate' -RequirementDigest $d1 -Status 'PASS' -Subject @{ source_sha = ('b' * 40); github_run_id = 12; artifact_id = 34; candidate_sha256 = ('c' * 64) } -EvidenceRefs @('production/evidence/x/index.json#artifact')
Assert-Equal $gate.status 'PASS' 'evidence-backed gate may be PASS'

Assert-Throws {
    New-ArthurGateRecord -GateId 'ARTIFACT' -RequirementRef 'x' -RequirementDigest $d1 -Status 'PASS' -Subject @{} -EvidenceRefs @()
} 'PASS without evidence must fail closed'

$current = @{ source_sha = ('d' * 40); github_run_id = 12; artifact_id = 34; candidate_sha256 = ('c' * 64) }
Assert-Equal (Resolve-ArthurGateStatus -Gate $gate -CurrentSubject $current) 'STALE' 'source change must stale source-bound artifact evidence'
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```powershell
pwsh -NoProfile -File tests/arthur-state-contract.tests.ps1
```

Expected: FAIL because `scripts/arthur-state-contract.ps1` does not exist.

- [ ] **Step 3: Implement the minimal pure helper**

Implement deterministic SHA256 helpers, exact allowed status validation, evidence-required PASS validation, subject comparison, requirement digest comparison, and ordered next-Gate selection. Keep the module side-effect free.

Core signatures:

```powershell
function New-ArthurExecutionId {
    param([string]$TaskSlug,[string]$AcceptedSourceSha,[datetime]$Date)
}

function Get-ArthurRequirementDigest {
    param([string]$RequirementText)
}

function New-ArthurGateRecord {
    param(
        [string]$GateId,
        [string]$RequirementRef,
        [string]$RequirementDigest,
        [ValidateSet('PENDING','RUNNING','PASS','FAIL','BLOCKED','STALE','SKIPPED')][string]$Status,
        [object]$Subject,
        [string[]]$EvidenceRefs = @(),
        [bool]$Inherited = $false,
        [string]$InheritedFrom = ''
    )
}

function Resolve-ArthurGateStatus {
    param([object]$Gate,[object]$CurrentSubject,[string]$CurrentRequirementDigest='')
}

function Get-ArthurNextRequiredGate {
    param([object[]]$Gates,[string[]]$GateOrder)
}
```

`Resolve-ArthurGateStatus` rules:
- changed requirement digest -> `STALE`;
- any subject key recorded by the Gate whose current value differs -> `STALE`;
- `PASS` without evidence and without inherited provenance -> throw/fail closed;
- existing `FAIL`, `BLOCKED`, `PENDING`, `RUNNING`, `SKIPPED` remain unchanged unless caller supplies an explicit transition.

- [ ] **Step 4: Run contract test and verify GREEN**

```powershell
pwsh -NoProfile -File tests/arthur-state-contract.tests.ps1
```

Expected: `ARTHUR_STATE_CONTRACT=PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/arthur-state-contract.ps1 tests/arthur-state-contract.tests.ps1
git commit -m "feat(state): add Arthur gate contract"
```

---

### Task 2: Add durable evidence-index metadata

**Files:**
- Create: `scripts/arthur-evidence-index.ps1`
- Create: `tests/arthur-evidence-index.tests.ps1`
- Modify: `scripts/classify-build-scope.sh`
- Modify: `tests/test-build-dedup-contract.sh`

**Interfaces:**
- Produces: `Get-ArthurEvidenceIndexPath`, `Read-ArthurEvidenceIndex`, `Add-ArthurEvidenceRecord`, `Find-ArthurGateEvidence`.
- Consumes: `execution_id`, Gate ID, producer identity, source/run/artifact/candidate/device identity, durable external or repository-local reference, SHA256 and result.

- [ ] **Step 1: Write failing evidence-index tests**

Test that one execution gets one deterministic path, append/update is atomic, duplicate evidence IDs do not create duplicates, and evidence-only paths classify as state/control-only.

```powershell
$path = Get-ArthurEvidenceIndexPath -Root $temp -ExecutionId 'arthur-adh-cn-aaaaaaa-20260908'
Assert-True ($path.EndsWith('production\evidence\arthur-adh-cn-aaaaaaa-20260908\index.json')) 'evidence path must be deterministic'

Add-ArthurEvidenceRecord -Path $path -Record @{
    evidence_id='artifact-12-34'; gate_id='ARTIFACT'; type='ARTIFACT_MANIFEST'; producer='test';
    source_sha=('a'*40); github_run_id=12; artifact_id=34; candidate_sha256=('b'*64);
    ref='github-artifact:34'; sha256=('c'*64); observed_at='2026-09-08T12:00:00Z'; result='PASS'
}
$index = Read-ArthurEvidenceIndex -Path $path
Assert-Equal @($index.evidence).Count 1 'evidence record must persist once'
```

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/arthur-evidence-index.tests.ps1
bash tests/test-build-dedup-contract.sh
```

Expected: PowerShell test fails because helper does not exist; build-dedup test fails after adding the new expected evidence path exclusion but before classifier implementation.

- [ ] **Step 3: Implement evidence-index helper**

Evidence index schema:

```json
{
  "schema_version": 1,
  "execution_id": "arthur-adh-cn-aaaaaaa-20260908",
  "evidence": []
}
```

`Add-ArthurEvidenceRecord` validates:
- `evidence_id`, `gate_id`, `type`, `producer`, `ref`, `observed_at`, `result` are non-empty;
- `observed_at` parses as offset-aware ISO 8601;
- SHA fields, when present, are exact lowercase/uppercase hex lengths after normalization;
- writes via temp file + atomic move;
- same `evidence_id` replaces only when identity fields are identical; conflicting duplicate ID fails closed.

- [ ] **Step 4: Exclude evidence indexes from firmware build scope**

Extend `scripts/classify-build-scope.sh` so `production/evidence/*/index.json` is `CONTROL_ONLY`, matching existing resume-state/event-ledger treatment. Update `tests/test-build-dedup-contract.sh` with an explicit evidence-index-only case.

- [ ] **Step 5: Verify GREEN**

```powershell
pwsh -NoProfile -File tests/arthur-evidence-index.tests.ps1
bash tests/test-build-dedup-contract.sh
```

Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/arthur-evidence-index.ps1 tests/arthur-evidence-index.tests.ps1 scripts/classify-build-scope.sh tests/test-build-dedup-contract.sh
git commit -m "feat(state): add durable Arthur evidence index"
```

---

### Task 3: Migrate resume-state resolution to schema v2 with v1 compatibility

**Files:**
- Modify: `scripts/arthur-resume-state.ps1`
- Modify: `tests/arthur-resume-state.tests.ps1`
- Modify: `production/resume-state.json`

**Interfaces:**
- Consumes: schema-v1 or schema-v2 previous snapshot, live device, accepted baseline, runtime state, execution identity, Gate evidence.
- Produces: schema-v2 canonical snapshot while retaining compatibility fields required by existing consumers.

- [ ] **Step 1: Add failing migration tests**

Add tests proving:
- schema-v1 previous snapshots are accepted as migration input;
- emitted state is `schema_version = 2`;
- `source.repository_head` and compatibility `repository_head` agree;
- `device` and compatibility `real_device` agree;
- `execution_id` is stable when already present;
- fixed `verified.*` strings no longer create Gate PASS by themselves;
- Gates with valid inherited evidence may remain PASS;
- changed requirement digest produces `STALE`;
- changed candidate SHA stales Candidate-dependent downstream Gates but not unrelated inherited Wi-Fi.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
```

Expected: FAIL on schema-v2/Gate assertions.

- [ ] **Step 3: Load the new helpers and construct schema v2**

At module top:

```powershell
. (Join-Path $PSScriptRoot 'arthur-state-contract.ps1')
```

Extend `Resolve-ArthurResumeState` with optional parameters:

```powershell
[string]$ExecutionId = '',
[object[]]$GateEvidence = @(),
[hashtable]$RequirementDigests = @{},
[hashtable]$CurrentSubjects = @{}
```

Return both new canonical fields and temporary compatibility fields:

```powershell
schema_version = 2
execution_id = $ExecutionId
source = @{ repository_head = $RepositoryHead; accepted_source_sha = $baselineSourceSha }
production = @{ github_run_id = $githubRunId; artifact_id = $artifactId; candidate_sha256 = $candidateSha }
device = @{ version = $liveVersion; build_id = $liveBuildId; git_commit = $liveCommit; evidence = $liveEvidence }
gates = $gateMap
current_gate = $phase
next_action = $resolvedNextAction

# compatibility during migration
repository_head = $RepositoryHead
real_device = $device
checkpoint = @{ current = $phase; next_action = $resolvedNextAction; turn_count = $turnCount }
verified = <summary derived from gateMap; never the source of PASS>
```

- [ ] **Step 4: Derive compatibility `verified` from Gates**

Map only for old readers:
- Gate valid PASS + inherited -> `VERIFIED_FROZEN` where appropriate;
- Gate valid PASS + live evidence -> legacy display string as needed;
- Gate STALE/FAIL/PENDING -> `REVERIFY_REQUIRED`.

No control decision may read `verified` after this task.

- [ ] **Step 5: Verify GREEN**

```powershell
pwsh -NoProfile -File tests/arthur-state-contract.tests.ps1
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
```

Expected: PASS.

- [ ] **Step 6: Update repository sample snapshot to schema v2 without claiming new evidence**

Migrate `production/resume-state.json` structurally. Existing assertions without durable evidence must not be upgraded to new Gate PASS. Use `PENDING`, `STALE`, or explicit inherited provenance matching currently stored accepted baseline evidence.

- [ ] **Step 7: Commit**

```bash
git add scripts/arthur-resume-state.ps1 tests/arthur-resume-state.tests.ps1 production/resume-state.json
git commit -m "feat(state): migrate Arthur resume snapshot to schema v2"
```

---

### Task 4: Make Control Plane the sole Gate arbiter and add state freshness reconciliation

**Files:**
- Modify: `scripts/arthur-control-plane.ps1`
- Modify: `tests/arthur-resume-state.tests.ps1`
- Modify: `tests/arthur-firmware-resume.tests.ps1`
- Modify: `scripts/arthur-firmware-resume.ps1`

**Interfaces:**
- Consumes: current non-state Git HEAD, operator intent, runtime/controller state, baseline, evidence indexes, live device identity, GitHub run/release observations.
- Produces: reconciled schema-v2 `resume-state.json`, Gate events, and exactly one permitted `next_action`.

- [ ] **Step 1: Write failing freshness/arbiter tests**

Require the Control Plane source to contain and behavior tests to prove:
- load `arthur-state-contract.ps1` and `arthur-evidence-index.ps1`;
- compute current non-state HEAD excluding `production/resume-state.json`, `production/firmware-events.jsonl`, and `production/evidence/*/index.json`;
- reconcile stale snapshot before instruction generation;
- if reconciliation cannot establish one identity, emit `STATE_RECONCILIATION_REQUIRED` and `instruction_allowed=false`;
- `next_action` comes from Gate status, not fixed `verified` strings;
- valid RUNNING Gate resumes same identity rather than dispatching duplicate work.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
pwsh -NoProfile -File tests/arthur-firmware-resume.tests.ps1
```

Expected: FAIL on new freshness/arbiter assertions.

- [ ] **Step 3: Add `STATE_FRESHNESS_GATE` reconciliation**

In Control Plane, before Publish/dispatch:
1. compute effective non-state HEAD;
2. load current snapshot and active execution/evidence index;
3. compare snapshot source/runtime/production/device identity;
4. call `Resolve-ArthurResumeState` with current evidence and requirement digests;
5. publish reconciled snapshot;
6. only dispatch when `instruction_allowed=true`.

The resume CLI must treat stale schema-v1/v2 snapshot or missing evidence as a reconciliation request, never as permission to reuse old PASS.

- [ ] **Step 4: Emit Gate events without breaking existing hash chain**

Use existing `Add-ArthurFirmwareEvent`; add event data fields `execution_id`, `gate_id`, `old_status`, `new_status`, `requirement_digest`, and subject identity. Keep event-ledger schema/hash algorithm unchanged.

- [ ] **Step 5: Publish state/evidence/ledger atomically at repository level**

When evidence index changes in the same reconciliation, stage:

```bash
git add -- production/resume-state.json production/firmware-events.jsonl production/evidence/<execution_id>/index.json
```

Do not add binaries/screenshots/output trees.

- [ ] **Step 6: Verify GREEN**

```powershell
pwsh -NoProfile -File tests/arthur-state-contract.tests.ps1
pwsh -NoProfile -File tests/arthur-evidence-index.tests.ps1
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
pwsh -NoProfile -File tests/arthur-firmware-resume.tests.ps1
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/arthur-control-plane.ps1 scripts/arthur-firmware-resume.ps1 tests/arthur-resume-state.tests.ps1 tests/arthur-firmware-resume.tests.ps1
git commit -m "feat(state): arbitrate Arthur gates in control plane"
```

---

### Task 5: Adapt Feature Handoff to carry `execution_id` and preview evidence identity

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Consumes: accepted feature ID/source SHA/preview evidence.
- Produces: durable handoff with stable `execution_id` and evidence submission metadata; existing idempotency key behavior remains intact.

- [ ] **Step 1: Add failing handoff tests**

Prove:
- an accepted preview creates or preserves one deterministic `execution_id`;
- resume after process restart preserves it;
- same `feature_id + accepted_preview_source_sha` cannot create a second execution;
- preview evidence is recorded as an observation reference, not a global production PASS;
- existing `BUILD_DISPATCHED`/`CONTROLLER_ATTACHED` idempotency remains unchanged.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/feature-handoff.tests.ps1
```

Expected: FAIL on execution/evidence assertions.

- [ ] **Step 3: Add execution identity to handoff state**

When accepting preview:

```powershell
$executionId = New-ArthurExecutionId -TaskSlug $FeatureId -AcceptedSourceSha $AcceptedPreviewSourceSha -Date (Get-Date)
```

Persist `execution_id` once. If existing state has one for the same accepted identity, reuse it; identity conflict fails closed.

- [ ] **Step 4: Preserve production dispatch semantics**

Do not change immutable tag/request dispatch or numeric v3 Run ID behavior. Add only enough metadata for the Control Plane to correlate the GitHub run with `execution_id`.

- [ ] **Step 5: Verify GREEN and commit**

```powershell
pwsh -NoProfile -File tests/feature-handoff.tests.ps1
```

```bash
git add scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat(state): bind feature handoff to execution identity"
```

---

### Task 6: Adapt Production Agent to submit artifact/flash/device evidence without becoming the arbiter

**Files:**
- Modify: `scripts/production-agent.ps1`
- Modify/Create: `tests/production-agent-evidence.tests.ps1`

**Interfaces:**
- Consumes: `execution_id` correlated from durable request/handoff plus existing numeric `run_id`.
- Produces: artifact, hash, flash-safety, flash-event, real-device and release evidence records; keeps its existing local stage state and at-most-once flash behavior.

- [ ] **Step 1: Add failing evidence-adapter tests**

Static/behavior tests must prove:
- state includes `execution_id` without changing numeric `run_id`;
- `Ensure-Artifact` records source SHA, run ID, artifact ID and Candidate SHA256 evidence;
- safety-gate completion records `FLASH_SAFETY_REPORT` evidence;
- `FLASH_STARTED` records a durable `FLASH_EVENT` before invoking sysupgrade;
- crash recovery after `FLASH_STARTED` still enters WAIT_DEVICE and never calls sysupgrade again;
- real-device verifier result is submitted as `REAL_DEVICE_REPORT` evidence;
- Production Agent does not directly write global Gate PASS into `resume-state.json`.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/production-agent-evidence.tests.ps1
```

Expected: FAIL because evidence adapter is absent.

- [ ] **Step 3: Add minimal evidence submission calls**

Load `arthur-evidence-index.ps1`. After each existing successful observation, call `Add-ArthurEvidenceRecord` with current execution/run/artifact/candidate/device identity. Preserve all existing safety and retry logic.

`FLASH_EVENT` must be written before the irreversible remote command begins so restart can reconcile instead of replaying the write.

- [ ] **Step 4: Verify GREEN**

```powershell
pwsh -NoProfile -File tests/production-agent-evidence.tests.ps1
```

Expected: PASS including the existing at-most-once flash assertion.

- [ ] **Step 5: Commit**

```bash
git add scripts/production-agent.ps1 tests/production-agent-evidence.tests.ps1
git commit -m "feat(state): submit production evidence to Arthur control plane"
```

---

### Task 7: Map frozen accepted features to explicit inherited evidence

**Files:**
- Modify: `scripts/arthur-control-plane.ps1`
- Modify: `tests/arthur-resume-state.tests.ps1`
- Create: `production/evidence/<active-execution>/index.json` only when the live reconciler can derive provenance from existing repository/live evidence; otherwise leave the Gate `STALE`/`PENDING`.

**Interfaces:**
- Consumes: `production/real-device-baseline.json`, `production/wifi-frozen-baseline.json`, accepted preview records, current live device evidence.
- Produces: explicit `INHERITED_BASELINE` or live evidence records for Wi-Fi, LuCI Chinese, AdGuard full manager and QuickStart only when provenance is actually demonstrable.

- [ ] **Step 1: Add failing inherited-evidence tests**

Prove:
- frozen Wi-Fi may be PASS only with explicit baseline evidence provenance and unaffected change impact;
- requirement digest change stales inherited evidence;
- LuCI/ADH/QuickStart fixed legacy strings cannot manufacture PASS;
- missing provenance leaves Gate `STALE` or `PENDING` rather than guessing.

- [ ] **Step 2: Verify RED**

```powershell
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
```

- [ ] **Step 3: Implement explicit inheritance mapping**

Use stored baseline paths/hashes and accepted-preview identity. Never invent evidence from chat or historical prose. Store references/hashes in the active evidence index.

- [ ] **Step 4: Verify GREEN and commit**

```powershell
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
```

```bash
git add scripts/arthur-control-plane.ps1 tests/arthur-resume-state.tests.ps1 production/evidence
git commit -m "feat(state): bind frozen Arthur gates to provenance"
```

---

### Task 8: Run full regression, documentation and release-scope safety checks

**Files:**
- Modify: `production/README.md`
- Modify: `production/GPT-FIRMWARE-EXECUTION-RULES.md`
- Modify: `AGENTS.md`
- Modify tests only if documentation contract assertions require exact new wording.

**Interfaces:**
- Produces: documented schema-v2 precedence, `NO EVIDENCE -> NO PASS`, `STALE` semantics, and startup rule that Codex/ChatGPT reads reconciled Gate state rather than historical narrative.

- [ ] **Step 1: Update documentation**

Document:
- `resume-state.json` schema v2 is current snapshot;
- `firmware-events.jsonl` is append-only history;
- `production/evidence/<execution_id>/index.json` is proof index;
- Control Plane is sole Gate arbiter;
- state-only changes do not authorize or trigger firmware execution;
- `STALE` means previously valid proof no longer applies.

- [ ] **Step 2: Run focused tests**

```powershell
pwsh -NoProfile -File tests/arthur-state-contract.tests.ps1
pwsh -NoProfile -File tests/arthur-evidence-index.tests.ps1
pwsh -NoProfile -File tests/arthur-resume-state.tests.ps1
pwsh -NoProfile -File tests/arthur-firmware-resume.tests.ps1
pwsh -NoProfile -File tests/feature-handoff.tests.ps1
pwsh -NoProfile -File tests/production-agent-evidence.tests.ps1
bash tests/test-build-dedup-contract.sh
```

Expected: all PASS.

- [ ] **Step 3: Run existing repository contract suite relevant to production state**

Run every existing `tests/*resume*.tests.ps1`, Feature Handoff test, functional-acceptance test, and build-dedup test. Do not trigger firmware build workflows.

Expected: all existing contract tests PASS.

- [ ] **Step 4: Verify branch diff is control/state-only**

```bash
git diff --name-only origin/main...HEAD
bash scripts/classify-build-scope.sh < <(git diff --name-only origin/main...HEAD)
```

Expected: state-contract implementation files are classified according to existing CI policy and no request/candidate/firmware source mutation has occurred unintentionally. Evidence indexes themselves must remain `CONTROL_ONLY`.

- [ ] **Step 5: Verify no irreversible action was introduced**

Search changed files for `sysupgrade`, `dd`, `mtd`, `uboot`, and raw partition commands. Any `sysupgrade` occurrence in `production-agent.ps1` must be the pre-existing historically verified path; this feature must not add a second write path.

- [ ] **Step 6: Commit documentation**

```bash
git add production/README.md production/GPT-FIRMWARE-EXECUTION-RULES.md AGENTS.md tests
git commit -m "docs(state): document Arthur evidence-backed resume contract"
```

- [ ] **Step 7: Final verification before PR**

Confirm:
- no firmware build/flash/release workflow was dispatched;
- branch contains only the intended control-plane/state/evidence changes;
- all tests above PASS;
- `PRODUCTION_RELEASED` remains the only terminal success;
- operator intent still gates build/upload/flash/release.
