# Arthur LIVE_PREVIEW → Production Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every accepted Arthur `LIVE_PREVIEW=PASS` durably continue, without a living Codex session, through accepted-source freeze, Git/CI integration, the existing v3 Candidate controller, Production Agent, formal real-device verification, and `PRODUCTION_RELEASED` unless the user explicitly requested a post-preview pause or a genuine safety blocker occurs.

**Architecture:** Add a small persistent Feature Handoff layer between the already working v0.1.3-style live-preview lane and the existing `ci-controller-v3.ps1` / `production-agent.ps1` release lane. The handoff owns only preview evidence, accepted-source identity, safe capture/freeze of previewed files into the repository overlay, Git/PR integration, one-time production dispatch, and durable recovery; it does not reimplement build, flash, or release logic. State lives outside the Codex/worktree lifecycle under `%LOCALAPPDATA%\XinZhaoWrt\FeatureHandoff\handoff.json`, and a current-user Scheduled Task resumes incomplete stages after process or Windows restart.

**Tech Stack:** PowerShell 7, Git CLI, GitHub CLI, Windows Scheduled Tasks, existing Bash static gates, GitHub Actions, existing Arthur v3 controller and Production Agent.

**Spec:** `docs/superpowers/specs/2026-09-03-live-preview-production-handoff-design.md`

## Global Constraints

- The only successful terminal state for a full Arthur feature/release task is `PRODUCTION_RELEASED`.
- `LIVE_PREVIEW=PASS` is a checkpoint, never a terminal state unless `pause_after_live_preview=true` was explicitly requested for that task.
- `WIFI=VERIFIED_FROZEN`; ordinary feature development and handoff must not modify or reload Wi-Fi.
- Run the mandatory Reuse Gate before feature implementation; the handoff preserves the accepted mature solution rather than rebuilding it locally from scratch.
- No force push, destructive reset/clean of user work, raw MTD/U-Boot/dd/partition writes, or bypass of `CHANGE_IMPACT_GATE`, `BASELINE_INHERITANCE_GATE`, `EXPECTED_DIFF_GATE`, `AUTO_FLASH_SAFETY_GATE`, or formal `REAL_DEVICE_VERIFY`.
- The Candidate must contain bytes equivalent to the accepted live preview. For preview-safe file-level features, freeze the accepted manifest entries into the repository `files/` overlay and record exact provenance/hashes.
- Do not rewrite `ci-controller-v3.ps1` Candidate/repair behavior or `production-agent.ps1` flash/release behavior; attach to them.
- Same `feature_id + accepted_preview_source_sha` must not dispatch the production build more than once. If the same base SHA reappears with a different accepted worktree diff hash, fail source-identity reconciliation rather than silently treating it as the same accepted state.
- Once production state is `FLASH_STARTED`, `WAIT_DEVICE`, or `REAL_DEVICE_VERIFY`, recovery must reconcile that run and must not create a second build/flash chain.

---

## File Structure

- Create `scripts/feature-handoff-lib.ps1` — pure/stateful helper functions for durable state, path safety, preview identity, overlay freeze, and idempotency decisions. No top-level orchestration.
- Create `scripts/feature-handoff.ps1` — stage-machine orchestrator for preview acceptance → source freeze → Git/PR → v3 dispatch → production monitoring.
- Create `scripts/install-feature-handoff.ps1` — register/restart the current-user recovery Scheduled Task.
- Create `scripts/feature-handoff-status.ps1` — compact human/Codex-readable view of durable handoff state.
- Create `tests/feature-handoff.tests.ps1` — behavioral tests using temporary repositories/state directories; no real router writes or real GitHub dispatch.
- Modify `scripts/live-preview-mature-safe.ps1` — write accepted preview evidence and start the handoff by default; pause only when explicitly requested.
- Modify `tests/test-live-preview-contract.sh` — enforce the new preview→handoff contract and pause semantics.
- Modify `scripts/classify-build-scope.sh` and `tests/test-classify-build-scope.sh` — classify new handoff scripts/state metadata as control-plane/FAST_GATE while accepted `files/` overlays retain their normal firmware-impact classification.
- Modify `.github/workflows/arthur-fast-preflight.yml` — run the new PowerShell handoff tests and parse the new scripts.
- Modify `tests/production-agent.tests.ps1` and `.github/workflows/production-agent-deploy.yml` — install/recover the handoff task in the same persistent Windows runtime and assert it does not replace the existing v3 controller/Production Agent.
- Modify `knowledge/V013-DEVELOPMENT-LOOP.md`, `knowledge/PROJECT-STATE.md`, and `AGENTS.md` — point the permanent default route at the implemented handoff instead of a documentation-only continuation rule.
- Create `production/accepted-preview/.gitkeep` only if Git requires the directory to exist before the first accepted record; otherwise let the first handoff create `production/accepted-preview/<feature-id>.json`.

---

### Task 1: Durable handoff state and idempotency primitives

**Files:**
- Create: `scripts/feature-handoff-lib.ps1`
- Create: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Produces: `New-FeatureHandoffState`, `Load-FeatureHandoffState`, `Save-FeatureHandoffState`, `Set-FeatureHandoffStage`, `Get-FeatureHandoffKey`, `Get-FirstIncompleteHandoffStage`, `Test-ProductionWriteInProgress`.
- State stages: `PREVIEW_ACCEPTED`, `LOCAL_CHANGES_CAPTURED`, `STATIC_VERIFIED`, `SOURCE_FROZEN`, `REMOTE_INTEGRATED`, `BUILD_DISPATCHED`, `CONTROLLER_ATTACHED`, `PRODUCTION_RUNNING`, `PRODUCTION_RELEASED`.

- [ ] **Step 1: Write failing state-machine tests**

Add tests that create a temporary runtime directory and assert a new state contains the exact schema and stages:

```powershell
$state = New-FeatureHandoffState `
    -FeatureId 'arthur-adh-quickstart' `
    -AcceptedPreviewSourceSha ('a' * 40) `
    -AcceptedDiffSha256 ('b' * 64) `
    -PreviewManifestSha256 ('c' * 64) `
    -PreviewManifestPath 'sources/live-preview-mature/manifest.json' `
    -PreviewEvidence @{ LIVE_PREVIEW='PASS'; ADGUARD_PREVIEW='PASS'; QUICKSTART_PREVIEW='PASS'; WIFI='VERIFIED_FROZEN' }

Assert-Equal $state.current_stage 'PREVIEW_ACCEPTED' 'new state starts at PREVIEW_ACCEPTED'
Assert-Equal $state.stage_status 'VERIFIED' 'accepted preview is a verified checkpoint'
Assert-Equal $state.dispatch_key "arthur-adh-quickstart:$('a' * 40)" 'dispatch key uses feature_id + accepted preview SHA'
Assert-True ($state.accepted_diff_sha256 -eq ('b' * 64)) 'accepted diff hash is retained for source-identity reconciliation'
```

Add restart/idempotency tests:

```powershell
Save-FeatureHandoffState -State $state -StatePath $statePath
$reloaded = Load-FeatureHandoffState -StatePath $statePath
Assert-Equal $reloaded.dispatch_key $state.dispatch_key 'state survives process restart'

$reloaded.dispatched_run_id = 12345
$reloaded.current_stage = 'BUILD_DISPATCHED'
Save-FeatureHandoffState -State $reloaded -StatePath $statePath
Assert-True (Test-ProductionWriteInProgress -Stage 'FLASH_STARTED') 'FLASH_STARTED forbids redispatch'
Assert-True (Test-ProductionWriteInProgress -Stage 'WAIT_DEVICE') 'WAIT_DEVICE forbids redispatch'
Assert-True (Test-ProductionWriteInProgress -Stage 'REAL_DEVICE_VERIFY') 'REAL_DEVICE_VERIFY forbids redispatch'
Assert-True (-not (Test-ProductionWriteInProgress -Stage 'CANDIDATE_VERIFIED')) 'pre-flash Candidate state is not itself a write-in-progress marker'
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL because `scripts/feature-handoff-lib.ps1` and its functions do not exist.

- [ ] **Step 3: Implement the minimal state helpers**

Implement constants and functions in `scripts/feature-handoff-lib.ps1`:

```powershell
$script:FeatureHandoffStages = @(
    'PREVIEW_ACCEPTED','LOCAL_CHANGES_CAPTURED','STATIC_VERIFIED','SOURCE_FROZEN',
    'REMOTE_INTEGRATED','BUILD_DISPATCHED','CONTROLLER_ATTACHED','PRODUCTION_RUNNING','PRODUCTION_RELEASED'
)

function Get-FeatureHandoffKey([string]$FeatureId,[string]$AcceptedPreviewSourceSha) {
    if ($FeatureId -notmatch '^[a-z0-9][a-z0-9._-]{2,80}$') { throw 'FEATURE_HANDOFF_INVALID_FEATURE_ID' }
    if ($AcceptedPreviewSourceSha -notmatch '^[0-9a-f]{40}$') { throw 'FEATURE_HANDOFF_INVALID_ACCEPTED_SHA' }
    return "$FeatureId`:$AcceptedPreviewSourceSha"
}

function Test-ProductionWriteInProgress([string]$Stage) {
    return $Stage -in @('FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY')
}
```

`Save-FeatureHandoffState` must write UTF-8 JSON atomically by writing `handoff.json.tmp` and then `Move-Item -Force` to the final path. `Load-FeatureHandoffState` must reject malformed JSON and unsupported `schema_version`.

- [ ] **Step 4: Run the tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS for state persistence, dispatch-key identity, restart, and no-duplicate-write markers.

- [ ] **Step 5: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: add durable Arthur feature handoff state"
```

---

### Task 2: Safe local-change capture and accepted preview source freeze

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Produces: `Get-FeatureChangedPaths`, `Assert-FeatureChangedPathsSafe`, `Get-WorktreeDiffSha256`, `Get-PreviewManifestIdentity`, `Freeze-PreviewManifestToOverlay`, `Write-AcceptedPreviewRecord`.
- Consumes: durable state helpers from Task 1.

- [ ] **Step 1: Add failing tests for protected paths, build-output exclusion, manifest hashing, and overlay freeze**

In a temporary git repository, create a committed base, then make feature changes plus a manifest entry:

```powershell
$manifest = @{
    schema_version = 1
    entries = @(
        @{ local = 'staging/AdGuardHome.lua'; remote = '/usr/lib/lua/luci/controller/AdGuardHome.lua'; mode = '0644' },
        @{ local = 'staging/AdGuardHome'; remote = '/etc/init.d/AdGuardHome'; mode = '0755' }
    )
} | ConvertTo-Json -Depth 8
Set-Content -LiteralPath (Join-Path $repo 'manifest.json') -Value $manifest -Encoding UTF8
```

Assert:

```powershell
$identity = Get-PreviewManifestIdentity -RepoRoot $repo -ManifestPath (Join-Path $repo 'manifest.json')
Assert-True ($identity.manifest_sha256 -match '^[0-9a-f]{64}$') 'manifest gets a stable SHA256'
Assert-Equal $identity.entries.Count 2 'both accepted preview files are represented'

Freeze-PreviewManifestToOverlay -RepoRoot $repo -ManifestPath (Join-Path $repo 'manifest.json')
Assert-True (Test-Path (Join-Path $repo 'files/usr/lib/lua/luci/controller/AdGuardHome.lua')) 'LuCI file frozen into firmware overlay'
Assert-True (Test-Path (Join-Path $repo 'files/etc/init.d/AdGuardHome')) 'init file frozen into firmware overlay'
```

Add hard failures for changes to:

```text
config/required-plugins.txt
config/arthur.config
config/arthur-known-good.lock
production/known-good.json
files/etc/config/wireless
files/etc/config/network
```

Add explicit exclusions for `work/`, `output/`, `build_dir/`, `staging_dir/`, `dl/`, and `tmp/` so those paths are never staged by handoff.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL on the newly referenced source-freeze helpers.

- [ ] **Step 3: Implement manifest identity and freeze**

Implement `Freeze-PreviewManifestToOverlay` so each manifest `remote` path maps exactly to `files/<remote-without-leading-slash>`. Reject traversal, absolute local paths outside `RepoRoot`, forbidden router paths, and missing local source files. Copy accepted bytes exactly, then verify source and destination SHA256 match.

For executable manifest entries (`mode` matching `0755`, `755`, or executable owner bit), run:

```powershell
& git -C $RepoRoot update-index --add --chmod=+x -- $overlayRelative
```

For non-executable entries, use `--chmod=-x` only when the file is already tracked executable; do not rewrite unrelated index state.

`Write-AcceptedPreviewRecord` must create `production/accepted-preview/<feature-id>.json` containing:

```json
{
  "schema_version": 1,
  "feature_id": "arthur-adh-quickstart",
  "accepted_preview_source_sha": "<40 hex>",
  "accepted_diff_sha256": "<64 hex>",
  "preview_manifest_sha256": "<64 hex>",
  "frozen_files": [
    {"remote":"/path","overlay":"files/path","sha256":"<64 hex>"}
  ],
  "preview_evidence": {},
  "deferred_acceptance": [],
  "wifi_state": "VERIFIED_FROZEN"
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS including exact-byte freeze and protected-path failures.

- [ ] **Step 5: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: freeze accepted live preview source"
```

---

### Task 3: Preview acceptance must start the handoff by default

**Files:**
- Create: `scripts/feature-handoff.ps1`
- Modify: `scripts/live-preview-mature-safe.ps1`
- Modify: `tests/feature-handoff.tests.ps1`
- Modify: `tests/test-live-preview-contract.sh`

**Interfaces:**
- `feature-handoff.ps1` parameters:

```powershell
param(
    [ValidateSet('Resume','RunOnce','Status')][string]$Mode='Resume',
    [string]$FeatureId='',
    [string]$AcceptedPreviewSourceSha='',
    [string]$PreviewManifestPath='',
    [string]$PreviewEvidencePath='',
    [switch]$PauseAfterLivePreview,
    [string]$RuntimeRoot=''
)
```

- `live-preview-mature-safe.ps1` adds `-FeatureId` (default `arthur-adh-quickstart`) and `-PauseAfterLivePreview`.

- [ ] **Step 1: Write failing contract tests**

Add assertions to `tests/test-live-preview-contract.sh`:

```bash
handoff="$ROOT/scripts/feature-handoff.ps1"
[[ -s "$handoff" ]] || fail 'feature handoff executor missing'
grep -Fq 'feature-handoff.ps1' "$safe" || fail 'successful mature preview must start durable feature handoff'
grep -Fq 'PauseAfterLivePreview' "$safe" || fail 'preview pause must require an explicit flag'
grep -Fq 'FEATURE_HANDOFF_STARTED=' "$safe" || fail 'preview must expose handoff start evidence'
! grep -Fq 'wait for the user' "$safe" || fail 'default preview path must not wait for human visual confirmation'
```

Extend PowerShell tests to verify a `PREVIEW_ACCEPTED` state can be initialized from an evidence file containing:

```json
{
  "LIVE_PREVIEW":"PASS",
  "ADGUARD_PREVIEW":"PASS",
  "QUICKSTART_PREVIEW":"PASS",
  "WIFI":"VERIFIED_FROZEN",
  "REAL_DEVICE_VERIFY":"NOT_RUN",
  "RELEASE_ALLOWED":false
}
```

and reject missing `LIVE_PREVIEW=PASS` or missing `WIFI=VERIFIED_FROZEN`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash ./tests/test-live-preview-contract.sh
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL because no handoff executor/trigger exists.

- [ ] **Step 3: Implement evidence creation and independent handoff start**

At the successful end of `live-preview-mature-safe.ps1`, after printing the preview markers, compute current project HEAD and write a JSON evidence file under a non-repository runtime directory:

```powershell
$acceptedSha = (& git -C $Root rev-parse HEAD).Trim()
$evidence = [ordered]@{
    LIVE_PREVIEW='PASS'
    ADGUARD_PREVIEW='PASS'
    QUICKSTART_PREVIEW='PASS'
    WIFI='VERIFIED_FROZEN'
    REAL_DEVICE_VERIFY='NOT_RUN'
    RELEASE_ALLOWED=$false
    ADGUARD_NETWORK_MUTATION_TEST='DEFERRED_TO_REAL_DEVICE_VERIFY'
    ADGUARD_WEB_RUNTIME_TEST='DEFERRED_TO_REAL_DEVICE_VERIFY'
}
```

If `-PauseAfterLivePreview` is set, emit `FEATURE_HANDOFF=PAUSED_BY_USER` and do not start the process. Otherwise start an independent PowerShell process:

```powershell
$handoffArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$handoff,
    '-Mode','Resume','-FeatureId',$FeatureId,
    '-AcceptedPreviewSourceSha',$acceptedSha,
    '-PreviewManifestPath',$ResolvedManifest,
    '-PreviewEvidencePath',$evidencePath
)
$proc = Start-Process -FilePath $pwsh -ArgumentList $handoffArgs -WorkingDirectory $Root -WindowStyle Hidden -PassThru
Write-Host "FEATURE_HANDOFF_STARTED=$($proc.Id)"
```

Do not wait for the handoff process before returning the preview result.

- [ ] **Step 4: Implement initial `feature-handoff.ps1` orchestration through `SOURCE_FROZEN`**

Dot-source the library. On first `Resume`, validate evidence, compute worktree diff SHA256, create/load durable state, capture safe changed paths, freeze manifest entries into `files/`, write the accepted-preview record, run static validation, and advance stages atomically.

Static validation for this stage must include:

```powershell
& bash (Join-Path $Root 'tests/test-live-preview-contract.sh')
if ($LASTEXITCODE -ne 0) { throw 'FEATURE_HANDOFF_STATIC_LIVE_PREVIEW_CONTRACT_FAILED' }
& bash (Join-Path $Root 'scripts/verify-project.sh')
if ($LASTEXITCODE -ne 0) { throw 'FEATURE_HANDOFF_STATIC_VERIFY_PROJECT_FAILED' }
```

Do not run build or router write operations in this task yet.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
bash ./tests/test-live-preview-contract.sh
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS; default preview path contains a durable handoff trigger and explicit pause is the only normal post-preview stop.

- [ ] **Step 6: Commit**

```bash
git add scripts/feature-handoff.ps1 scripts/live-preview-mature-safe.ps1 tests/feature-handoff.tests.ps1 tests/test-live-preview-contract.sh
git commit -m "feat: hand accepted live preview to durable continuation"
```

---

### Task 4: Safe Git/PR integration without losing preview changes

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Produces: `Ensure-HandoffFeatureBranch`, `Commit-HandoffChanges`, `Push-HandoffBranch`, `Ensure-HandoffPullRequest`, `Wait-HandoffPullRequestChecks`, `Merge-HandoffPullRequest`, `Assert-AcceptedSourceOnMain`.
- `REMOTE_INTEGRATED` state records `branch`, `feature_commit_sha`, `pr_number`, and `merge_sha`.

- [ ] **Step 1: Add failing Git integration tests using a local bare remote**

Create a temporary bare repository plus working clone. Start on `main`, add an accepted overlay file, and assert `Ensure-HandoffFeatureBranch` creates a feature branch without losing dirty bytes. Use a second clone to advance remote `main` and verify the handoff performs a normal ancestry check instead of force pushing.

Assert the generated branch name matches:

```text
feature/handoff-<feature-id>-<8-char-accepted-sha>
```

Assert command contracts contain no `push --force`, `reset --hard`, or `clean -fdx` in the handoff files.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL on missing Git integration functions.

- [ ] **Step 3: Implement branch/commit/push behavior**

Rules:

```text
if current branch == main and worktree has accepted changes:
    git switch -c feature/handoff-<feature-id>-<shortsha>
else:
    keep current non-main feature branch

git fetch origin main
if origin/main is not ancestor of HEAD:
    git merge --no-edit origin/main
    if conflict: BLOCKED_SOURCE_RECONCILIATION (preserve worktree, no reset)
```

Stage only the paths captured in handoff state plus the frozen overlay paths and `production/accepted-preview/<feature>.json`. Never `git add -A`.

Commit message:

```text
feat: freeze accepted <feature-id> live preview
```

Push with plain:

```text
git push -u origin <branch>
```

- [ ] **Step 4: Implement PR creation/check/merge with GitHub CLI**

Use `gh pr list --head <branch> --base main --state open --json number,headRefOid` to reuse an existing PR; otherwise create one. Wait for checks using `gh pr checks <number> --watch --fail-fast=false`. If checks fail, classify as recoverable and leave the state at `SOURCE_FROZEN`/integration retry rather than asking the user.

Merge only if the PR head SHA still equals the recorded feature commit:

```text
gh pr merge <number> --merge --match-head-commit <feature_commit_sha>
```

Then fetch `origin/main` and require the accepted record plus all frozen overlay SHA256 values to match before `REMOTE_INTEGRATED`.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS for local branch preservation, ancestry handling, no destructive Git operations, and accepted-source verification helpers.

- [ ] **Step 6: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: integrate accepted preview source safely"
```

---

### Task 5: One-time v3 dispatch and production-state attachment

**Files:**
- Modify: `scripts/feature-handoff-lib.ps1`
- Modify: `scripts/feature-handoff.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Produces: `Select-HandoffBuildPlan`, `Dispatch-ArthurV3Once`, `Find-DispatchedArthurRun`, `Ensure-V3ControllerRecovery`, `Read-ProductionAgentState`, `Reconcile-ProductionState`.
- Consumes: `merge_sha` and accepted-source record from Task 4.
- `BUILD_DISPATCHED` records `selected_build_lane`, `v3_mode`, `dispatch_key`, and `dispatched_run_id`.

- [ ] **Step 1: Add failing build-plan/idempotency tests**

Test a source-lock-preserving accepted overlay change:

```powershell
$plan = Select-HandoffBuildPlan -ChangedPaths @(
    'files/usr/lib/lua/luci/controller/AdGuardHome.lua',
    'files/etc/init.d/AdGuardHome',
    'production/accepted-preview/arthur-adh-quickstart.json'
) -KnownGoodLockChanged:$false
Assert-Equal $plan.v3_mode 'rebuild_known_good' 'overlay-only accepted source preserves frozen package lock'
Assert-True ([string]$plan.reason -match 'source-lock-preserving') 'build decision records why v3 rebuild is valid'
```

Test a changed `config/arthur-known-good.lock` fails closed instead of silently selecting `rebuild_known_good`.

Test existing state with `dispatched_run_id=555` returns that run without another dispatch. Test production stages `FLASH_STARTED`, `WAIT_DEVICE`, `REAL_DEVICE_VERIFY` suppress all dispatch attempts.

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: FAIL on missing production attachment helpers.

- [ ] **Step 3: Implement build-plan selection**

Feed accepted changed paths through `scripts/classify-build-scope.sh` and persist its result as `selected_build_lane`. For this handoff version, a source-lock-preserving preview overlay is formally dispatched through the already production-integrated v3 mode `rebuild_known_good`; this is the shortest currently integrated lane that produces artifacts compatible with the existing v3 Controller/Production Agent. Do not change package refs mechanically.

If the accepted change includes the protected Known-Good lock or cannot prove that the preview bytes are represented by the frozen overlay, throw `FEATURE_HANDOFF_SOURCE_IDENTITY_UNPROVEN` before dispatch.

- [ ] **Step 4: Implement one-time workflow dispatch and run discovery**

Use:

```text
gh workflow run arthur-update-v3.yml --repo mxonline/xinzhaowrt --ref main -f mode=rebuild_known_good
```

Record dispatch timestamp, then discover the run with:

```text
gh run list --repo mxonline/xinzhaowrt --workflow arthur-update-v3.yml --branch main --event workflow_dispatch --limit 20 --json databaseId,createdAt,status,conclusion,headSha
```

Only accept a run whose `headSha == merge_sha` and `createdAt >= dispatch_started_at - 3s`. Persist `dispatched_run_id` before starting/attaching controllers. On restart, an existing `dispatched_run_id` wins; never dispatch again for the same state.

- [ ] **Step 5: Attach existing recovery infrastructure**

If `XinZhaoWrt-Arthur-v3-Controller` exists, start it and mark `CONTROLLER_ATTACHED`. If missing, dispatch `production-agent-deploy.yml` once and leave the handoff in retryable `BUILD_DISPATCHED` until the scheduled task appears; do not build a second controller.

Read `%LOCALAPPDATA%\XinZhaoWrt\ProductionAgent\output\production-agent\state.json`. If its `run_id` matches the handoff run:

```text
FLASH_STARTED / WAIT_DEVICE / REAL_DEVICE_VERIFY -> PRODUCTION_RUNNING, never redispatch
PRODUCTION_RELEASED -> handoff PRODUCTION_RELEASED terminal success
BLOCKED with an approved hard safety human_gate -> handoff BLOCKED with same evidence
ordinary RETRYING/recoverable -> keep monitoring/retry
```

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS for one-time dispatch, source-identity failure, production-stage reconciliation, and terminal release mapping.

- [ ] **Step 7: Commit**

```bash
git add scripts/feature-handoff-lib.ps1 scripts/feature-handoff.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: attach feature handoff to Arthur v3 production"
```

---

### Task 6: Windows recovery Scheduled Task and persistent runtime deployment

**Files:**
- Create: `scripts/install-feature-handoff.ps1`
- Create: `scripts/feature-handoff-status.ps1`
- Modify: `.github/workflows/production-agent-deploy.yml`
- Modify: `tests/production-agent.tests.ps1`
- Modify: `tests/feature-handoff.tests.ps1`

**Interfaces:**
- Scheduled Task: `XinZhaoWrt-Arthur-Feature-Handoff`.
- Task action: PowerShell 7 runs `scripts/feature-handoff.ps1 -Mode Resume` from `%LOCALAPPDATA%\XinZhaoWrt\ProductionAgent`.
- Task principal: current interactive user, highest run level; never SYSTEM/LocalSystem.

- [ ] **Step 1: Write failing install/recovery contract tests**

Add to `tests/production-agent.tests.ps1`:

```powershell
Assert-True (Test-Path (Join-Path $Root 'scripts/feature-handoff.ps1')) 'feature handoff executor missing'
Assert-True (Test-Path (Join-Path $Root 'scripts/install-feature-handoff.ps1')) 'feature handoff installer missing'
Assert-Contains $deploy "'scripts/feature-handoff.ps1'" 'handoff changes must redeploy persistent Windows runtime'
Assert-Contains $deploy 'XinZhaoWrt-Arthur-Feature-Handoff' 'deploy must ensure handoff recovery task is installed'
Assert-True ($installHandoff -notmatch '(?i)SYSTEM|LocalSystem') 'handoff task must run in the interactive user context'
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/production-agent.tests.ps1
```

Expected: FAIL because installer/status scripts and deploy wiring do not exist.

- [ ] **Step 3: Implement the handoff installer**

Follow the existing `install-production-agent.ps1` PowerShell-resolution pattern. Register:

```powershell
$TaskName='XinZhaoWrt-Arthur-Feature-Handoff'
$Action=New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Handoff`" -Mode Resume" -WorkingDirectory $Root
$LogonTrigger=New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$Settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$Principal=New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
```

Start the task after registration. `feature-handoff.ps1 -Mode Resume` must exit 0 with `FEATURE_HANDOFF=IDLE` when no durable handoff exists, so login recovery is safe.

- [ ] **Step 4: Implement compact status output**

`feature-handoff-status.ps1` reads durable state and prints at minimum:

```text
FEATURE_HANDOFF_STAGE=<stage>
FEATURE_HANDOFF_STATUS=<status>
FEATURE_ID=<feature_id>
ACCEPTED_SOURCE_SHA=<sha>
MERGE_SHA=<sha-or-empty>
RUN_ID=<id-or-0>
PRODUCTION_STAGE=<stage-or-empty>
LAST_ERROR=<compact-message>
```

- [ ] **Step 5: Wire into persistent deployment workflow**

Add the new scripts/tests to `production-agent-deploy.yml` path filters. After the stable runtime sync, run `install-feature-handoff.ps1`, then verify the task exists. Do not remove or rename `XinZhaoWrt-Arthur-v3-Controller` or `XinZhaoWrt-Arthur-Production-Agent`.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File ./tests/production-agent.tests.ps1
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

Expected: PASS for installation contract, current-user principal, safe idle recovery, and coexistence with existing production tasks.

- [ ] **Step 7: Commit**

```bash
git add scripts/install-feature-handoff.ps1 scripts/feature-handoff-status.ps1 .github/workflows/production-agent-deploy.yml tests/production-agent.tests.ps1 tests/feature-handoff.tests.ps1
git commit -m "feat: persist Arthur feature handoff recovery"
```

---

### Task 7: CI/build-scope gates and permanent project routing

**Files:**
- Modify: `scripts/classify-build-scope.sh`
- Modify: `tests/test-classify-build-scope.sh`
- Modify: `.github/workflows/arthur-fast-preflight.yml`
- Modify: `knowledge/V013-DEVELOPMENT-LOOP.md`
- Modify: `knowledge/PROJECT-STATE.md`
- Modify: `AGENTS.md`

**Interfaces:**
- New handoff scripts/tests are `FAST_GATE` control-plane changes.
- Accepted `files/` overlay paths retain their existing firmware-impact classification and must never be downgraded merely because the handoff created them.

- [ ] **Step 1: Add failing scope/CI tests**

Add a case to `tests/test-classify-build-scope.sh`:

```bash
run_case FAST_GATE \
  scripts/feature-handoff.ps1 \
  scripts/feature-handoff-lib.ps1 \
  scripts/install-feature-handoff.ps1 \
  scripts/feature-handoff-status.ps1 \
  tests/feature-handoff.tests.ps1
```

Add/retain a case proving an accepted overlay such as `files/usr/lib/lua/luci/controller/AdGuardHome.lua` is not classified `DOC_ONLY` or `FAST_GATE`.

- [ ] **Step 2: Run scope test and verify RED**

Run:

```bash
bash ./tests/test-classify-build-scope.sh
```

Expected: FAIL because new handoff paths are currently unknown and therefore fail closed to `FULL_BUILD`.

- [ ] **Step 3: Update classifier and Fast Preflight**

Add only the four control scripts to the `FAST_GATE` case in `scripts/classify-build-scope.sh`. Do not add broad `files/**` exceptions.

In `arthur-fast-preflight.yml`, add PowerShell parser checks for the four new scripts and run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
```

alongside the existing live-preview and production-agent contracts.

- [ ] **Step 4: Update permanent routing docs to point to executable handoff**

Replace any wording that implies `LIVE_PREVIEW=PASS` depends on Codex continuing manually. State the executable rule:

```text
LIVE_PREVIEW=PASS -> Feature Handoff durable state -> accepted-source freeze -> Git/CI -> v3 Controller -> Production Agent -> PRODUCTION_RELEASED
```

Keep the explicit exception: `pause_after_live_preview=true` may pause after preview. Keep `WIFI=VERIFIED_FROZEN` and mandatory Reuse Gate.

- [ ] **Step 5: Run full static verification**

Run:

```bash
bash ./tests/test-classify-build-scope.sh
bash ./tests/test-live-preview-contract.sh
bash ./scripts/verify-project.sh
```

Run:

```powershell
pwsh -NoProfile -File ./tests/feature-handoff.tests.ps1
pwsh -NoProfile -File ./tests/production-agent.tests.ps1
```

Parse every changed PowerShell file:

```powershell
$changed = git diff --name-only origin/main...HEAD | Where-Object { $_ -like '*.ps1' }
foreach ($file in $changed) {
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file),[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw "$file parser errors: $($errors.Message -join '; ')" }
}
```

Expected: all PASS, zero parser errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/classify-build-scope.sh tests/test-classify-build-scope.sh .github/workflows/arthur-fast-preflight.yml knowledge/V013-DEVELOPMENT-LOOP.md knowledge/PROJECT-STATE.md AGENTS.md
git commit -m "docs: enforce persistent v013 feature handoff"
```

---

### Task 8: End-to-end dry-run, PR CI, and real handoff activation

**Files:**
- No new architecture files expected; only minimal fixes discovered by verification are allowed.

**Interfaces:**
- Input: current Arthur mature ADH + QuickStart feature with existing `LIVE_PREVIEW=PASS` evidence.
- Output before actual firmware production: durable handoff reaches at least `BUILD_DISPATCHED` with one real v3 `run_id`, without repeating live preview or modifying Wi-Fi.
- Final output of the existing production chain: `PRODUCTION_RELEASED` only after formal post-flash `REAL_DEVICE_VERIFY=PASS`.

- [ ] **Step 1: Run all tests locally in the isolated implementation worktree**

Run the complete commands from Task 7 and `git diff --check`.

Expected: all PASS.

- [ ] **Step 2: Push implementation branch and open PR**

Use normal push and PR; no force push. Wait for `Arthur Fast Preflight` and `Arthur Production Agent CI` to pass on the exact head SHA.

- [ ] **Step 3: Merge normally and verify persistent runtime deployment**

After CI passes, merge the PR normally. Confirm `Arthur Production Agent Deploy` syncs the new runtime and installs:

```text
XinZhaoWrt-Arthur-Feature-Handoff
XinZhaoWrt-Arthur-v3-Controller
XinZhaoWrt-Arthur-Production-Agent
```

Do not claim the handoff is active from code/CI alone; require task/runtime evidence.

- [ ] **Step 4: Reconcile the already accepted current feature without rerunning unsafe ADH network preview actions**

Use the existing accepted mature ADH + QuickStart preview evidence. Initialize the durable handoff with the accepted feature id/source/manifest and let it capture/freeze the accepted files. Do not rerun ADH start/stop/network mutation in LIVE_PREVIEW; those remain deferred to formal `REAL_DEVICE_VERIFY`.

Expected checkpoint:

```text
FEATURE_HANDOFF_STAGE=BUILD_DISPATCHED
FEATURE_HANDOFF_STATUS=LIVE
RUN_ID=<new v3 run>
WIFI=VERIFIED_FROZEN
```

- [ ] **Step 5: Verify no duplicate dispatch across one forced process restart**

Stop only the handoff process (not the v3 Controller or Production Agent), start `XinZhaoWrt-Arthur-Feature-Handoff`, and confirm the same `RUN_ID` is retained. No second `arthur-update-v3` workflow dispatch may appear for the same dispatch key.

- [ ] **Step 6: Allow existing production chain to continue unattended**

Observe durable state progression only; do not introduce a new manual gate:

```text
BUILD_DISPATCHED -> CONTROLLER_ATTACHED -> PRODUCTION_RUNNING -> PRODUCTION_RELEASED
```

Formal post-flash verification must exercise the deferred ADH network-mutating/runtime acceptance items and restore AdGuard Home to its required default disabled state.

- [ ] **Step 7: Final verification before claiming completion**

Require fresh evidence for:

```text
PRODUCTION_RELEASED=YES
REAL_DEVICE_VERIFY=PASS
ADGUARD_REAL_DEVICE=PASS
QUICKSTART_REAL_DEVICE=PASS
WIFI=VERIFIED_FROZEN
```

Also verify the released source/accepted-preview record contains the same frozen file hashes as the preview identity. Only then report the handoff implementation and current Arthur release task complete.

- [ ] **Step 8: Commit only if end-to-end verification required a minimal code fix**

If no fix was needed, do not create an empty commit. If a fix was needed, rerun the exact failing test plus the full verification suite before committing a focused repair.
