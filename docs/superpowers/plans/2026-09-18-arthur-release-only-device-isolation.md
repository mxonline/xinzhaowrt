# Arthur RELEASE_ONLY Device Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent real-device SSH/HTTP probes from blocking the existing Arthur v0.1.5 `RELEASE_ONLY` execution while preserving all device safety checks for `FLASH_AND_VERIFY`, then resume the same execution through GitHub Release and verify the published bytes and provenance.

**Architecture:** Add a small PowerShell routing helper that validates the release mode and wraps device-observation callbacks. `RELEASE_ONLY` returns a skipped observation without invoking callbacks; `FLASH_AND_VERIFY` invokes the supplied callback and preserves existing failure behavior. The control plane will use the helper for both SSH and HTTP probes and will use the frozen real-device baseline only as rollback evidence when RELEASE_ONLY has no live device.

**Tech Stack:** Windows PowerShell, GitHub Actions, GitHub CLI, existing Arthur resume-state/event-ledger helpers, PowerShell contract tests.

**Spec:** `production/release-policy.md`, `production/release-mode.json`, `production/ARTHUR_PRODUCT_TARGETS.md`, and execution `arthur-v0.1.5-release-e037750-20260918`.

## Global Constraints

- Preserve accepted product source SHA `e0377509dcc57c415935e9f779fe27117ce591be`.
- Preserve execution id `arthur-v0.1.5-release-e037750-20260918`; do not authorize another execution.
- Keep `RELEASE_ONLY`, `automatic_flash=false`, `device_write_authorized=false`, and `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`.
- Do not execute sysupgrade, raw writes, SSH upload, reboot-for-flash, or any real-router mutation.
- `RELEASE_ONLY` must proceed through `CHANGE_IMPACT → BASELINE_INHERITANCE → EXPECTED_DIFF → BUILD → ARTIFACT → RELEASE_GATE → RELEASE → PRODUCTION_RELEASED`.
- `FLASH_AND_VERIFY` must retain the existing device identity, host-key, reachability, safety-gate, and sysupgrade protections.
- After BUILD, reuse the exact candidate bytes; do not rebuild because of a control-plane retry.
- A success claim requires GitHub Release asset, SHA256, source, run, artifact, and provenance readback evidence.

### Task 1: Add a failing device-probe routing regression test

**Files:**
- Create: `tests/arthur-control-plane-release-only-device-isolation.tests.ps1`
- Modify: `.github/workflows/arthur-control-plane-gates.yml`

**Interfaces:**
- Consumes: `scripts/arthur-control-plane-device-routing.ps1` functions defined in Task 2.
- Produces: An automated contract covering offline, SSH host-key mismatch, device unreachable, and the preserved FLASH_AND_VERIFY callback path.

- [ ] **Step 1: Write the failing test**

Create a PowerShell test that dot-sources the routing helper, sends each of these simulated failures through a callback, and asserts RELEASE_ONLY never invokes the callback or throws:

```powershell
$failures = @(
    @{ name = 'offline'; error = 'DEVICE_OFFLINE' },
    @{ name = 'ssh-host-key-mismatch'; error = 'REMOTE HOST IDENTIFICATION HAS CHANGED' },
    @{ name = 'unreachable'; error = 'DEVICE_UNREACHABLE' }
)

foreach ($failure in $failures) {
    $called = $false
    $result = Invoke-ArthurControlPlaneDeviceObservation -ReleaseMode 'RELEASE_ONLY' -Action {
        $script:called = $true
        throw $failure.error
    }
    Assert-True (-not $called) "RELEASE_ONLY must not invoke device observation for $($failure.name)"
    Assert-True ([bool]$result.skipped) "RELEASE_ONLY must skip $($failure.name)"
    Assert-Equal ([string]$result.reason) 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED' "RELEASE_ONLY skip reason must be explicit for $($failure.name)"
}

$flashCalled = $false
$flashResult = Invoke-ArthurControlPlaneDeviceObservation -ReleaseMode 'FLASH_AND_VERIFY' -Action {
    $script:flashCalled = $true
    return 'probe-result'
}
Assert-True $flashCalled 'FLASH_AND_VERIFY must keep invoking device observation'
Assert-True (-not [bool]$flashResult.skipped) 'FLASH_AND_VERIFY must not skip device observation'
Assert-Equal ([string]$flashResult.value) 'probe-result' 'FLASH_AND_VERIFY must preserve the probe result'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/arthur-control-plane-release-only-device-isolation.tests.ps1`

Expected: FAIL because `scripts/arthur-control-plane-device-routing.ps1` and `Invoke-ArthurControlPlaneDeviceObservation` do not exist yet.

- [ ] **Step 3: Add the test to the control-plane gate workflow**

Add the helper and test paths to the `pull_request` path filter and run the test beside the existing control-plane contract tests:

```yaml
- 'scripts/arthur-control-plane-device-routing.ps1'
- 'tests/arthur-control-plane-release-only-device-isolation.tests.ps1'
```

```powershell
./tests/arthur-control-plane-release-only-device-isolation.tests.ps1
```

- [ ] **Step 4: Commit the red test**

```powershell
git add tests/arthur-control-plane-release-only-device-isolation.tests.ps1 .github/workflows/arthur-control-plane-gates.yml
git commit -m "test: cover release-only device probe isolation"
```

### Task 2: Implement the minimal RELEASE_ONLY routing helper

**Files:**
- Create: `scripts/arthur-control-plane-device-routing.ps1`

**Interfaces:**
- Consumes: release mode string supplied by the control plane.
- Produces: `Invoke-ArthurControlPlaneDeviceObservation -ReleaseMode <mode> -Action <scriptblock>` returning `{ skipped, reason, value }`.

- [ ] **Step 1: Write the minimal helper**

Implement only the two supported modes. RELEASE_ONLY must return before evaluating the callback; FLASH_AND_VERIFY must evaluate it and return its value. Unknown modes must fail closed:

```powershell
Set-StrictMode -Version Latest

function Invoke-ArthurControlPlaneDeviceObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('RELEASE_ONLY','FLASH_AND_VERIFY')][string]$ReleaseMode,
        [Parameter(Mandatory=$true)][scriptblock]$Action
    )

    if ($ReleaseMode -eq 'RELEASE_ONLY') {
        return [pscustomobject][ordered]@{
            skipped = $true
            reason = 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED'
            value = $null
        }
    }

    return [pscustomobject][ordered]@{
        skipped = $false
        reason = 'FLASH_AND_VERIFY_DEVICE_OBSERVATION_REQUIRED'
        value = (& $Action)
    }
}
```

- [ ] **Step 2: Run the focused test to verify it passes**

Run: `pwsh -NoProfile -File tests/arthur-control-plane-release-only-device-isolation.tests.ps1`

Expected: PASS for all three RELEASE_ONLY failure simulations and the FLASH_AND_VERIFY callback path.

- [ ] **Step 3: Commit the minimal helper**

```powershell
git add scripts/arthur-control-plane-device-routing.ps1
git commit -m "fix: isolate release-only device observation"
```

### Task 3: Wire the main control plane without weakening FLASH_AND_VERIFY

**Files:**
- Modify: `scripts/arthur-control-plane.ps1:194-347,445-448`
- Modify: `tests/arthur-control-plane-release-only-device-isolation.tests.ps1`

**Interfaces:**
- Consumes: `Invoke-ArthurControlPlaneDeviceObservation` from Task 2 and `production/release-mode.json`.
- Produces: Mode-aware control-plane reconciliation. RELEASE_ONLY never executes SSH/HTTP device probes and uses baseline fallback for resume identity; FLASH_AND_VERIFY preserves existing probe, identity, and fail-closed status logic.

- [ ] **Step 1: Extend the failing test with source-order and baseline assertions**

Read the control-plane script as text and assert it loads the helper, reads `release-mode.json`, wraps both the SSH and HTTP probe calls, logs an explicit RELEASE_ONLY skip, and passes `-AllowBaselineFallbackForMissingLiveDevice` only for RELEASE_ONLY. Also assert the legacy status strings remain present:

```powershell
$controlPlane = Get-Content -Raw (Join-Path $Root 'scripts/arthur-control-plane.ps1')
Assert-Contains $controlPlane 'arthur-control-plane-device-routing.ps1' 'control plane must load device routing helper'
Assert-Contains $controlPlane 'Invoke-ArthurControlPlaneDeviceObservation' 'control plane must route device observations through the mode gate'
Assert-Contains $controlPlane 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED' 'release-only skip must be observable'
Assert-Contains $controlPlane 'RETRY_DEVICE_UNAVAILABLE' 'FLASH_AND_VERIFY reachability protection must remain'
Assert-Contains $controlPlane 'REMOTE HOST IDENTIFICATION HAS CHANGED' 'host-key safety evidence must remain available to FLASH_AND_VERIFY'
```

- [ ] **Step 2: Run the test to verify the new assertions fail**

Run: `pwsh -NoProfile -File tests/arthur-control-plane-release-only-device-isolation.tests.ps1`

Expected: FAIL on the missing helper load, wrapper, and RELEASE_ONLY skip until the control plane is wired.

- [ ] **Step 3: Implement the mode gate in the control plane**

After helper imports and before any device probe, read and validate `production/release-mode.json`. Wrap the existing SSH call and HTTP `build-info` request in `Invoke-ArthurControlPlaneDeviceObservation`. For a skipped result, emit an explicit `DEVICE_PROBE=SKIPPED_RELEASE_ONLY` record and set device build-info sources to `NOT_REQUIRED_RELEASE_ONLY`; do not classify the device as unreachable or identity-invalid.

When calling `Resolve-ArthurResumeState`, pass `-AllowBaselineFallbackForMissingLiveDevice:($releaseMode -eq 'RELEASE_ONLY')`. Keep the existing live-device provenance expression and `RETRY_DEVICE_UNAVAILABLE`, `BLOCKED_DEVICE_IDENTITY`, and `RECOVERABLE_BUILD_INFO_PROVENANCE` decisions unchanged for `FLASH_AND_VERIFY`; for RELEASE_ONLY, do not derive the continuation decision from `$device.reachable`, `$device.classification`, or live HTTP/SSH fields.

- [ ] **Step 4: Run the focused regression test**

Run: `pwsh -NoProfile -File tests/arthur-control-plane-release-only-device-isolation.tests.ps1`

Expected: PASS, including all three simulated device failures and the retained FLASH_AND_VERIFY path.

- [ ] **Step 5: Run existing control-plane contracts**

Run: `pwsh -NoProfile -File tests/arthur-control-plane-executor.tests.ps1; pwsh -NoProfile -File tests/arthur-control-plane-gates.tests.ps1; pwsh -NoProfile -File tests/production-agent-release-only.tests.ps1`

Expected: all existing contracts and the new isolation test pass with no parser errors.

- [ ] **Step 6: Commit the control-plane wiring**

```powershell
git add scripts/arthur-control-plane.ps1 tests/arthur-control-plane-release-only-device-isolation.tests.ps1
git commit -m "fix: keep release-only resume independent of device reachability"
```

### Task 4: Verify the candidate-safe code change and publish the control-plane fix

**Files:**
- Review: `scripts/arthur-control-plane.ps1`, `scripts/arthur-control-plane-device-routing.ps1`, `production/operator-intent.json`, `production/resume-state.json`, `production/release-mode.json`

- [ ] **Step 1: Verify source and execution invariants before push**

Run:

```powershell
git status --short --branch
git diff refs/remotes/github-main...HEAD --stat
git show refs/remotes/github-main:production/operator-intent.json
git show refs/remotes/github-main:production/release-mode.json
```

Expected: only the routing/helper/test/workflow changes are present; accepted source SHA and execution id remain unchanged; no firmware source/config/build artifacts are changed.

- [ ] **Step 2: Run PowerShell parser checks and focused contracts**

Run:

```powershell
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts/arthur-control-plane.ps1'), [ref]`$null, [ref]`$null)"
pwsh -NoProfile -File tests/arthur-control-plane-release-only-device-isolation.tests.ps1
pwsh -NoProfile -File tests/arthur-control-plane-executor.tests.ps1
pwsh -NoProfile -File tests/arthur-control-plane-gates.tests.ps1
```

Expected: parser and all contracts pass.

- [ ] **Step 3: Push only the control-plane fix to GitHub main**

After the fresh evidence check, push the reviewed commit(s) to `origin main`. Do not alter the accepted product source commit or production authorization files.

- [ ] **Step 4: Dispatch the existing Arthur Control Plane workflow**

Use the existing `Arthur Control Plane` `workflow_dispatch` on `main`, with no new execution id or authorization payload. Confirm the run reads execution `arthur-v0.1.5-release-e037750-20260918` and starts at `CHANGE_IMPACT`.

### Task 5: Monitor the existing execution to terminal release

**Files:**
- Verify: current GitHub main `production/resume-state.json`, `production/firmware-events.jsonl`, `production/evidence/arthur-v0.1.5-release-e037750-20260918/index.json`, GitHub run/artifact/release metadata.

- [ ] **Step 1: Confirm CHANGE_IMPACT through EXPECTED_DIFF**

Wait for the same execution to advance automatically. Do not manually approve intermediate gates. If it stops, classify the exact fail-closed blocker and preserve the required `BLOCKED/root_cause/machine_evidence/failed_gate/next_action` evidence.

- [ ] **Step 2: Confirm BUILD and record the immutable candidate identity**

Read the run summary and state/event ledger. Confirm BUILD passes for source `e037750...`, Arthur target/profile and all 22 required plugins; record run id, artifact id, candidate asset names, and SHA256. Do not start a second build.

- [ ] **Step 3: Confirm ARTIFACT → RELEASE_GATE → RELEASE**

Confirm artifact manifests and candidate hashes match, then verify the release gate does not require SSH, host key, device reachability, sysupgrade, or `POST_RELEASE_DEVICE_TEST`.

- [ ] **Step 4: Confirm PRODUCTION_RELEASED by readback**

Only after GitHub Release asset download/hash/provenance readback matches the candidate, source SHA, run id, and artifact id, verify current main reports:

```text
status=PRODUCTION_RELEASED
current_gate=PRODUCTION_RELEASED
next_action=NONE
post_release_device_test=PENDING_INDEPENDENT
```

Confirm `production/known-good.json` remains the previous device-confirmed rollback authority.
