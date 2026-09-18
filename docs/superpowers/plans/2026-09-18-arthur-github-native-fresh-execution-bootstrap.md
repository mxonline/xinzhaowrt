# Arthur GitHub-Native Fresh Execution Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start an explicitly authorized fresh Arthur `RELEASE_ONLY` execution from a previous terminal release entirely inside GitHub Actions, permanently removing the Windows/DPAPI host-push bridge from this startup path.

**Architecture:** Add a focused bootstrap helper that validates operator intent, release policy, version identity, source ancestry, prior terminal state, and remote-head identity; creates the fresh schema-v2 resume/evidence/event state; and publishes only state/evidence/event files from the GitHub Actions checkout. Invoke it before the existing Resume Gate and wake the control plane on `production/operator-intent.json` changes.

**Tech Stack:** PowerShell 7 / Windows PowerShell-compatible project helpers, Git, GitHub Actions, existing Arthur schema-v2 state/evidence/event helpers.

**Spec:** `docs/superpowers/specs/2026-09-18-arthur-github-native-fresh-execution-bootstrap-design.md`

## Global Constraints

- Current authorized execution: `arthur-v0.1.5-release-e037750-20260918`.
- Current product source: `e0377509dcc57c415935e9f779fe27117ce591be`.
- Target release: `v0.1.5`; repository `VERSION` must equal `0.1.5`.
- Release mode remains exactly `RELEASE_ONLY`.
- `automatic_flash=false`, `device_write_authorized=false`, `sysupgrade_forbidden=true`.
- Never invoke or depend on `run-host-main-push.ps1`, `github-app-bridge`, DPAPI, PAT, JWT, GitHub App private-key material, or `C:\Users\chenz` for fresh execution bootstrap.
- Never modify `production/known-good.json` in this change.
- `production/firmware-events.jsonl` is append-only.
- Normal push only; no force push.
- Existing product repair code and OpenClash/AdGuardHome implementation are out of scope.

---

### Task 1: Lock the regression contract with failing tests

**Files:**
- Create: `tests/arthur-fresh-execution-bootstrap.tests.ps1`
- Modify: `.github/workflows/arthur-control-plane-gates.yml`

**Interfaces:**
- Consumes: existing `production/operator-intent.json`, `production/release-mode.json`, `production/resume-state.json`, `VERSION`, state/evidence/event helper contracts.
- Produces: a CI-enforced behavioral contract for `scripts/arthur-fresh-execution-bootstrap.ps1` and integration ordering in `scripts/arthur-control-plane-gate.ps1`.

- [ ] **Step 1: Write failing static and behavioral tests**

The test must fail while the bootstrap helper is absent and must assert all of the following:

```powershell
$BootstrapPath = Join-Path $Root 'scripts\arthur-fresh-execution-bootstrap.ps1'
Assert-True (Test-Path -LiteralPath $BootstrapPath -PathType Leaf) 'fresh execution bootstrap helper must exist'

$bootstrap = Get-Content -Raw $BootstrapPath
Assert-NotContains $bootstrap 'run-host-main-push.ps1' 'fresh bootstrap must not use host push bridge'
Assert-NotContains $bootstrap 'github-app-bridge' 'fresh bootstrap must not use GitHub App bridge'
Assert-NotContains $bootstrap 'DPAPI' 'fresh bootstrap must not depend on DPAPI'
Assert-NotContains $bootstrap 'C:\Users\chenz' 'fresh bootstrap must not depend on user-specific worktree paths'

$gate = Get-Content -Raw (Join-Path $Root 'scripts\arthur-control-plane-gate.ps1')
$bootstrapCall = $gate.IndexOf('Invoke-ArthurFreshExecutionBootstrap',[StringComparison]::OrdinalIgnoreCase)
$resumeCall = $gate.IndexOf('& $resumeGatePath',[StringComparison]::OrdinalIgnoreCase)
Assert-True ($bootstrapCall -ge 0 -and $resumeCall -gt $bootstrapCall) 'fresh bootstrap must run before Resume Gate'

$workflow = Get-Content -Raw (Join-Path $Root '.github\workflows\arthur-control-plane.yml')
Assert-Contains $workflow "production/operator-intent.json" 'operator authorization changes must wake the control plane'
```

Behavioral fixtures must cover:

```text
terminal old execution + valid new authorized execution -> BOOTSTRAP_REQUIRED
same execution -> NOOP_CURRENT_EXECUTION
unauthorized intent -> NOOP_NOT_AUTHORIZED
VERSION != target_release -> fail closed
release mode != RELEASE_ONLY -> fail closed
automatic_flash=true -> fail closed
device_write_authorized=true -> fail closed
sysupgrade_forbidden=false -> fail closed
active_source_sha not ancestor/current repository lineage -> fail closed
remote main != local head -> fail closed before publication
known-good file digest unchanged
existing event ledger prefix byte-for-byte unchanged; exactly one new event appended
```

- [ ] **Step 2: Run test and verify RED**

Run:

```powershell
pwsh -NoProfile -File ./tests/arthur-fresh-execution-bootstrap.tests.ps1
```

Expected: FAIL specifically because `scripts/arthur-fresh-execution-bootstrap.ps1` does not exist / bootstrap integration is absent.

- [ ] **Step 3: Wire the failing test into PR CI**

Update `.github/workflows/arthur-control-plane-gates.yml` so its `paths` include the new helper/test and its test step runs both:

```powershell
./tests/arthur-control-plane-gates.tests.ps1
./tests/arthur-fresh-execution-bootstrap.tests.ps1
```

- [ ] **Step 4: Commit RED state**

```bash
git add tests/arthur-fresh-execution-bootstrap.tests.ps1 .github/workflows/arthur-control-plane-gates.yml
git commit -m "test: define fresh execution bootstrap contract"
```

---

### Task 2: Implement the minimal GitHub-native bootstrap helper

**Files:**
- Create: `scripts/arthur-fresh-execution-bootstrap.ps1`
- Test: `tests/arthur-fresh-execution-bootstrap.tests.ps1`

**Interfaces:**
- Produces: `Invoke-ArthurFreshExecutionBootstrap -Root <repo> -RepositoryHead <40hex> -RemoteMainHead <40hex> -Apply:$bool`.
- Return object fields: `action`, `execution_id`, `previous_execution_id`, `target_release`, `repository_head`, `accepted_source_sha`, `resume_state`, `evidence_index`, `event`.

- [ ] **Step 1: Implement validation only**

The helper must dot-source existing project helpers, read JSON safely, validate the global constraints, and return `BOOTSTRAP_REQUIRED`, `NOOP_CURRENT_EXECUTION`, or `NOOP_NOT_AUTHORIZED` without mutating files when `-Apply:$false`.

- [ ] **Step 2: Run the bootstrap test**

Expected: validation tests pass; apply/publication tests may still fail.

- [ ] **Step 3: Implement fresh state construction**

Construct a new schema-v2 state with:

```text
execution_id = operator-intent.execution_id
status = RESUME_SAFE
instruction_allowed = true
release = operator-intent.target_release
source.repository_head = current workflow checkout HEAD
source.accepted_source_sha = operator-intent.firmware_state.active_source_sha
production.github_run_id = 0
production.artifact_id = 0
current_gate = CHANGE_IMPACT
next_action = CHANGE_IMPACT
checkpoint.current = CHANGE_IMPACT
checkpoint.next_action = CHANGE_IMPACT
conflicts = []
post_release_device_test = PENDING_INDEPENDENT
```

Gate initialization rules:

```text
FORENSICS / ADH_MANAGEMENT / ADH_CHINESE = SKIPPED
operator-intent.firmware_state.verified_frozen gates = inherited PASS only if the prior gate is PASS and requirement identity is unchanged
all remaining release-relevant gates = PENDING
no BUILD/ARTIFACT/RELEASE gate may be PASS at bootstrap
```

Create a fresh evidence index:

```json
{"schema_version":1,"execution_id":"<new execution>","evidence":[]}
```

Create one execution-aware event payload for `EXECUTION_STARTED` with the new execution ID, target release, product source, repository head, and `RELEASE_ONLY` mode.

- [ ] **Step 4: Verify GREEN for pure behavior**

Run:

```powershell
pwsh -NoProfile -File ./tests/arthur-fresh-execution-bootstrap.tests.ps1
```

Expected: PASS for all pure-state and fail-closed cases.

- [ ] **Step 5: Commit helper**

```bash
git add scripts/arthur-fresh-execution-bootstrap.ps1 tests/arthur-fresh-execution-bootstrap.tests.ps1
git commit -m "feat: add GitHub-native fresh execution bootstrap"
```

---

### Task 3: Publish fresh state safely from the existing control-plane gate

**Files:**
- Modify: `scripts/arthur-control-plane-gate.ps1`
- Modify: `scripts/arthur-fresh-execution-bootstrap.ps1`
- Test: `tests/arthur-fresh-execution-bootstrap.tests.ps1`

**Interfaces:**
- Consumes: bootstrap result from Task 2.
- Produces: a normal Git commit/push of only `resume-state.json`, the new execution evidence index, and the append-only event ledger before the existing Resume Gate executes.

- [ ] **Step 1: Add publication tests first**

Tests must verify the apply path refuses to publish unless local HEAD and fetched `origin/main` are equal, stages only the allowed state/evidence/event files, never stages `known-good.json`, and never constructs a force push command.

- [ ] **Step 2: Run and verify RED**

Expected: publication tests fail because apply behavior is not implemented.

- [ ] **Step 3: Implement `-Apply` publication**

Required order:

```text
git fetch origin main
resolve local HEAD
resolve refs/remotes/origin/main
require equality
write new resume state
write new evidence index
append one firmware event using existing ledger helper
git add only allowed paths
git commit -m "chore(state): bootstrap <execution_id> [skip ci]"
git push origin HEAD:main
git fetch origin main
require refs/remotes/origin/main == new local HEAD
```

On non-fast-forward or any identity mismatch: fail closed; do not retry with force.

- [ ] **Step 4: Integrate before Resume Gate**

In `arthur-control-plane-gate.ps1`, load the helper and call it before `$failureRecoveryPath` / `$resumeGatePath` continuation logic. A successful bootstrap updates the checkout state and then the existing Resume Gate must be executed normally; bootstrap does not bypass it.

- [ ] **Step 5: Run tests and commit**

```powershell
pwsh -NoProfile -File ./tests/arthur-fresh-execution-bootstrap.tests.ps1
pwsh -NoProfile -File ./tests/arthur-control-plane-gates.tests.ps1
```

Expected: PASS.

```bash
git add scripts/arthur-control-plane-gate.ps1 scripts/arthur-fresh-execution-bootstrap.ps1 tests/arthur-fresh-execution-bootstrap.tests.ps1
git commit -m "fix: bootstrap fresh execution before resume gate"
```

---

### Task 4: Make operator authorization wake the existing control plane

**Files:**
- Modify: `.github/workflows/arthur-control-plane.yml`
- Modify: `.github/workflows/arthur-control-plane-gates.yml`
- Test: `tests/arthur-fresh-execution-bootstrap.tests.ps1`

**Interfaces:**
- Produces: GitHub-native wakeup on a new operator authorization; no host script needed.

- [ ] **Step 1: Add the failing workflow assertion**

Assert `.github/workflows/arthur-control-plane.yml` contains this push path:

```yaml
- 'production/operator-intent.json'
```

and still targets the self-hosted `xinzhaowrt-controller` runner with `contents: write`.

- [ ] **Step 2: Verify RED**

Expected: FAIL before workflow modification.

- [ ] **Step 3: Add the path trigger and preserve release-only safety**

Do not add `resume-state.json`, evidence, or event-ledger paths to the wake trigger; bootstrap state commits use `[skip ci]` and must not create recursive control-plane runs.

- [ ] **Step 4: Run both contract tests**

```powershell
pwsh -NoProfile -File ./tests/arthur-control-plane-gates.tests.ps1
pwsh -NoProfile -File ./tests/arthur-fresh-execution-bootstrap.tests.ps1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/arthur-control-plane.yml .github/workflows/arthur-control-plane-gates.yml tests/arthur-fresh-execution-bootstrap.tests.ps1
git commit -m "ci: wake Arthur control plane on fresh authorization"
```

---

### Task 5: Full verification and current v0.1.5 handoff

**Files:**
- Verify only; no new product-code changes.

**Interfaces:**
- Consumes: merged bootstrap feature and existing v0.1.5 operator intent.
- Produces: fresh durable execution and unattended `RELEASE_ONLY` continuation.

- [ ] **Step 1: Run targeted tests**

```powershell
pwsh -NoProfile -File ./tests/arthur-fresh-execution-bootstrap.tests.ps1
pwsh -NoProfile -File ./tests/arthur-control-plane-gates.tests.ps1
pwsh -NoProfile -File ./tests/arthur-resume-state-v2.tests.ps1
pwsh -NoProfile -File ./tests/arthur-state-consistency.tests.ps1
pwsh -NoProfile -File ./tests/production-agent-release-only.tests.ps1
```

Expected: all PASS.

- [ ] **Step 2: Run static syntax checks for changed PowerShell files**

Parser errors must be zero.

- [ ] **Step 3: Verify forbidden architecture is absent**

```text
fresh bootstrap references run-host-main-push.ps1 = 0
fresh bootstrap references github-app-bridge = 0
fresh bootstrap references DPAPI = 0
fresh bootstrap references C:\Users\chenz = 0
fresh bootstrap contains force push = 0
```

- [ ] **Step 4: Merge only after PR CI is green**

Use the exact reviewed PR head SHA. Do not merge if the head moved or required checks are failing.

- [ ] **Step 5: Observe the merge-triggered Arthur Control Plane**

Required bootstrap evidence:

```text
FRESH_EXECUTION_BOOTSTRAP=PASS
EXECUTION_ID=arthur-v0.1.5-release-e037750-20260918
TARGET_RELEASE=v0.1.5
RELEASE_MODE=RELEASE_ONLY
DEVICE_WRITE_AUTHORIZED=false
REMOTE_STATE_PUBLICATION=PASS
RESUME_GATE=PASS
```

- [ ] **Step 6: Continue unattended release**

Allow only:

```text
CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> BUILD -> ARTIFACT -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED
```

Forbidden:

```text
PRE_FLASH / AUTO_FLASH_SAFETY_GATE / FLASH / WAIT_DEVICE / sysupgrade / SSH upload / router reboot / Known-Good promotion
```

- [ ] **Step 7: Terminal verification**

Success requires real GitHub evidence for:

```text
GITHUB_RELEASE=v0.1.5
PRODUCTION_RELEASED=PASS
FLASH=NOT_RUN
SYSUPGRADE=NOT_RUN
POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT
KNOWN_GOOD_PROMOTION=NOT_RUN
```
