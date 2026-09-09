$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ReconcilerPath = Join-Path $Root 'scripts\arthur-terminal-release-reconciler.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

function Write-TestJson {
    param([string]$Path,$Value)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Read-TestJson {
    param([string]$Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Get-TerminalEventCount {
    param([string]$Path,[long]$RunId,[string]$StableTag)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(
        Get-Content -LiteralPath $Path |
            Where-Object { $_.Trim() } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object {
                $_.event -eq 'PRODUCTION_RELEASED' -and
                [long]$_.data.run_id -eq $RunId -and
                $_.data.stable_tag -eq $StableTag
            }
    ).Count
}

function New-TerminalReconcileFixture {
    param(
        [string]$Directory,
        [string]$ExecutionId = 'arthur-final-release-5f41c4e-20260908',
        [string]$TerminalExecutionId = 'arthur-final-release-5f41c4e-20260908'
    )

    $runId = 34268801985
    $stableTag = 'arthur-production-34268801985'
    $sourceSha = '2f4d9a70e5675955bddaf51eb134131fac61bfc3'
    $firmware = 'XinZhaoWrt-Arthur-v0.1.3-20260908-sysupgrade.bin'
    $sha256 = 'f048a7063c7fa89774f628d252f9709d5cee2801f36066ebefb61cc65ea1b557'
    $paths = @{
        status = Join-Path $Directory 'status.json'
        known_good = Join-Path $Directory 'known-good.json'
        release_evidence = Join-Path $Directory 'github-release-evidence.json'
        device_evidence = Join-Path $Directory 'real-device-evidence.json'
        resume = Join-Path $Directory 'resume-state.json'
        intent = Join-Path $Directory 'operator-intent.json'
        runtime = Join-Path $Directory 'runtime-state.json'
        events = Join-Path $Directory 'firmware-events.jsonl'
    }

    $identity = [ordered]@{
        run_id = $runId
        stable_tag = $stableTag
        project_commit = $sourceSha
        source_commit = $sourceSha
        firmware = $firmware
        sha256 = $sha256
    }
    Write-TestJson $paths.status ([ordered]@{
        status = 'PRODUCTION_RELEASED'; known_good = $true; verification = 'real-device-confirmed'
        run_id = $runId; stable_tag = $stableTag; project_commit = $sourceSha; source_commit = $sourceSha
        firmware = $firmware; sha256 = $sha256
    })
    Write-TestJson $paths.known_good ([ordered]@{
        verified = $true; verification = 'real-device-confirmed'; known_good = $true
        toolchain_run = $runId; run_id = $runId; stable_tag = $stableTag; project_commit = $sourceSha
        source_commit = $sourceSha; firmware = $firmware; firmware_file = $firmware; sha256 = $sha256
    })
    Write-TestJson $paths.release_evidence ([ordered]@{
        verified_by = 'GITHUB_ACTIONS_GITHUB_TOKEN'; release_exists = $true; draft = $false; prerelease = $false
        run_id = $runId; stable_tag = $stableTag; project_commit = $sourceSha; source_commit = $sourceSha
        firmware = $firmware; sha256 = $sha256
    })
    Write-TestJson $paths.device_evidence ([ordered]@{
        verified = $true; verification = 'real-device-confirmed'; known_good = $true
        run_id = $runId; stable_tag = $stableTag; project_commit = $sourceSha; source_commit = $sourceSha
        firmware = $firmware; sha256 = $sha256
    })
    Write-TestJson $paths.resume ([ordered]@{
        execution_id = $ExecutionId; status = 'RESUME_SAFE'; instruction_allowed = $true
        current_gate = 'PRE_FLASH'; next_action = 'PRE_FLASH'; pending = @('PRE_FLASH'); conflicts = @()
        checkpoint = [ordered]@{ current = 'PRE_FLASH'; next_action = 'PRE_FLASH' }
        production = [ordered]@{ github_run_id = 34242450515 }
        source = [ordered]@{ accepted_source_sha = '5f41c4e25be6eb5a24f78bc794ca1d80a036087c' }
    })
    Write-TestJson $paths.intent ([ordered]@{
        execution_id = $ExecutionId; intent_type = 'EXECUTE_FIRMWARE'; authorization_scope = 'FIRMWARE_RELEASE'
        firmware_execution_authorized = $true
        firmware_state = [ordered]@{
            current_stage = 'PRE_FLASH'; next_stage = 'AUTO_FLASH_SAFETY_GATE'; active_run_id = 34242450515
            active_source_sha = '5f41c4e25be6eb5a24f78bc794ca1d80a036087c'
        }
    })
    Write-TestJson $paths.runtime ([ordered]@{
        execution_id = $ExecutionId; phase = 'SAFETY_BLOCKED'; current_stage = 'PRE_FLASH'
        next_action = 'PRE_FLASH'; terminal_state = $null; pending_human_gate = 'AUTO_FLASH_SAFETY_GATE'
    })
    Set-Content -LiteralPath $paths.events -Value '' -Encoding utf8NoBOM
    return [pscustomobject]@{
        Paths = $paths
        Identity = [pscustomobject]$identity
        ExecutionId = $ExecutionId
        TerminalExecutionId = $TerminalExecutionId
    }
}

function Invoke-TestReconcile {
    param([pscustomobject]$Fixture)
    return Invoke-ArthurTerminalReleaseReconcile `
        -StatusPath $Fixture.Paths.status `
        -KnownGoodPath $Fixture.Paths.known_good `
        -ReleaseEvidencePath $Fixture.Paths.release_evidence `
        -DeviceEvidencePath $Fixture.Paths.device_evidence `
        -ResumeStatePath $Fixture.Paths.resume `
        -OperatorIntentPath $Fixture.Paths.intent `
        -RuntimeStatePath $Fixture.Paths.runtime `
        -EventLogPath $Fixture.Paths.events `
        -ExecutionId $Fixture.TerminalExecutionId
}

function Assert-TerminalSnapshot {
    param([pscustomobject]$Fixture)
    $resume = Read-TestJson $Fixture.Paths.resume
    $intent = Read-TestJson $Fixture.Paths.intent
    $runtime = Read-TestJson $Fixture.Paths.runtime
    $identity = $Fixture.Identity

    Assert-Equal $resume.status 'PRODUCTION_RELEASED' 'terminal evidence must close stale resume state'
    Assert-Equal $resume.instruction_allowed $false 'terminal resume must never issue another execution instruction'
    Assert-Equal $resume.current_gate 'PRODUCTION_RELEASED' 'terminal resume must advance current gate'
    Assert-Equal $resume.next_action 'NONE' 'terminal resume must have no next action'
    Assert-Equal @($resume.pending).Count 0 'terminal resume must have no pending gates'
    Assert-Equal @($resume.conflicts).Count 0 'terminal resume must not retain stale checkpoint conflicts'
    Assert-Equal $resume.checkpoint.current 'PRODUCTION_RELEASED' 'checkpoint current must be terminal'
    Assert-Equal $resume.checkpoint.next_action 'NONE' 'checkpoint next action must be terminal'
    Assert-Equal ([long]$resume.production.github_run_id) $identity.run_id 'resume must use published production run identity'

    Assert-Equal $intent.firmware_execution_authorized $false 'completed execution must no longer authorize firmware mutation'
    Assert-Equal $intent.firmware_state.current_stage 'PRODUCTION_RELEASED' 'intent current stage must be terminal'
    Assert-Equal $intent.firmware_state.next_stage 'NONE' 'intent next stage must be closed'
    Assert-Equal ([long]$intent.firmware_state.active_run_id) $identity.run_id 'intent must use published production run identity'
    Assert-Equal $intent.firmware_state.active_source_sha $identity.source_commit 'intent must use published production source identity'

    Assert-Equal $runtime.phase 'PRODUCTION_RELEASED' 'matching stale runtime must be superseded by terminal evidence'
    Assert-Equal $runtime.current_stage 'PRODUCTION_RELEASED' 'runtime current stage must be terminal'
    Assert-Equal $runtime.next_action 'NONE' 'runtime next action must be closed'
    Assert-Equal $runtime.terminal_state 'PRODUCTION_RELEASED' 'runtime must record terminal state'
    Assert-True ($null -eq $runtime.pending_human_gate) 'terminal runtime must clear pending human gate'
}

function Assert-ReconcileFailsClosed {
    param([pscustomobject]$Fixture,[string]$Message)
    $before = @{}
    foreach ($path in $Fixture.Paths.Values) {
        $before[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }
    $threw = $false
    try { Invoke-TestReconcile $Fixture | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
    foreach ($path in $Fixture.Paths.Values) {
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash $before[$path] "$Message must not write $path"
    }
}

Assert-True (Test-Path -LiteralPath $ReconcilerPath) 'Invoke-ArthurTerminalReleaseReconcile implementation must exist'
. $ReconcilerPath

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-terminal-reconciler-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    # Break caught: retaining PRE_FLASH after matching durable production evidence would reopen a completed release.
    $forwardDir = Join-Path $testRoot 'forward'
    New-Item -ItemType Directory -Path $forwardDir -Force | Out-Null
    $forward = New-TerminalReconcileFixture -Directory $forwardDir
    Invoke-TestReconcile $forward | Out-Null
    Assert-TerminalSnapshot $forward
    Assert-Equal (Get-TerminalEventCount -Path $forward.Paths.events -RunId $forward.Identity.run_id -StableTag $forward.Identity.stable_tag) 1 'forward closure must append one semantic terminal event'

    # Break caught: a retry that appends another terminal event or mutates a settled snapshot is not idempotent.
    $beforeResume = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.resume).Hash
    $beforeIntent = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.intent).Hash
    $beforeRuntime = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.runtime).Hash
    Invoke-TestReconcile $forward | Out-Null
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.resume).Hash $beforeResume 'second terminal reconciliation must not rewrite resume state'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.intent).Hash $beforeIntent 'second terminal reconciliation must not rewrite operator intent'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.runtime).Hash $beforeRuntime 'second terminal reconciliation must not rewrite runtime state'
    Assert-Equal (Get-TerminalEventCount -Path $forward.Paths.events -RunId $forward.Identity.run_id -StableTag $forward.Identity.stable_tag) 1 'second terminal reconciliation must not append a duplicate event'

    # Break caught: missing server-side release proof must never manufacture a local terminal state.
    $missingReleaseDir = Join-Path $testRoot 'missing-release'
    New-Item -ItemType Directory -Path $missingReleaseDir -Force | Out-Null
    $missingRelease = New-TerminalReconcileFixture -Directory $missingReleaseDir
    Remove-Item -LiteralPath $missingRelease.Paths.release_evidence -Force
    $beforeMissing = @{}
    foreach ($path in @($missingRelease.Paths.status,$missingRelease.Paths.known_good,$missingRelease.Paths.device_evidence,$missingRelease.Paths.resume,$missingRelease.Paths.intent,$missingRelease.Paths.runtime,$missingRelease.Paths.events)) {
        $beforeMissing[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }
    $threw = $false
    try { Invoke-TestReconcile $missingRelease | Out-Null } catch { $threw = $true }
    Assert-True $threw 'missing verified GitHub release evidence must fail closed'
    foreach ($path in $beforeMissing.Keys) { Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash $beforeMissing[$path] 'missing release evidence must not write state' }

    # Break caught: mismatched identity across durable sources must fail closed without writing any state.
    $mismatchDir = Join-Path $testRoot 'mismatch'
    New-Item -ItemType Directory -Path $mismatchDir -Force | Out-Null
    $mismatch = New-TerminalReconcileFixture -Directory $mismatchDir
    $badEvidence = Read-TestJson $mismatch.Paths.release_evidence
    $badEvidence.sha256 = ('0' * 64)
    Write-TestJson $mismatch.Paths.release_evidence $badEvidence
    Assert-ReconcileFailsClosed $mismatch 'mismatched GitHub release firmware identity must fail closed'

    # Break caught: stale SAFETY_BLOCKED runtime from the completed execution must not win over durable terminal evidence.
    $runtimeDir = Join-Path $testRoot 'runtime-supersession'
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $runtimeFixture = New-TerminalReconcileFixture -Directory $runtimeDir
    Invoke-TestReconcile $runtimeFixture | Out-Null
    $runtimeAfter = Read-TestJson $runtimeFixture.Paths.runtime
    Assert-Equal $runtimeAfter.terminal_state 'PRODUCTION_RELEASED' 'matching stale runtime must be terminally superseded'
    Assert-Equal $runtimeAfter.next_action 'NONE' 'superseded runtime must not resume PRE_FLASH'

    # Break caught: closing one completed execution must not block a separately authorized new execution.
    $newExecutionDir = Join-Path $testRoot 'new-execution'
    New-Item -ItemType Directory -Path $newExecutionDir -Force | Out-Null
    $newExecution = New-TerminalReconcileFixture -Directory $newExecutionDir -ExecutionId 'arthur-new-execution-20260909'
    $beforeNewIntent = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.intent).Hash
    $beforeNewRuntime = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.runtime).Hash
    Invoke-TestReconcile $newExecution | Out-Null
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.intent).Hash $beforeNewIntent 'terminal reconcile must not close a distinct new execution intent'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.runtime).Hash $beforeNewRuntime 'terminal reconcile must not overwrite a distinct new execution runtime'
    $newIntent = Read-TestJson $newExecution.Paths.intent
    Assert-Equal $newIntent.firmware_execution_authorized $true 'new execution remains independently eligible after prior terminal release'

    Write-Host 'ARTHUR_TERMINAL_RELEASE_RECONCILER_CONTRACT=PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
