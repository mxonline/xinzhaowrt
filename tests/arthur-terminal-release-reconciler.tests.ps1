$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ReconcilerPath = Join-Path $Root 'scripts\arthur-terminal-release-reconciler.ps1'
$LedgerPath = Join-Path $Root 'scripts\arthur-firmware-event-ledger.ps1'

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
        gates = [ordered]@{
            PRE_FLASH = [ordered]@{
                gate_id = 'PRE_FLASH'; status = 'PENDING'; requirement_ref = 'production/release-policy.md#pre-flash'
                requirement_digest = ('a' * 64); subject = [ordered]@{ source_sha = '5f41c4e25be6eb5a24f78bc794ca1d80a036087c'; github_run_id = 34242450515 }
                evidence_refs = @(); inherited = $false; inherited_from = ''; verified_at = ''
            }
            PRODUCTION_RELEASED = [ordered]@{
                gate_id = 'PRODUCTION_RELEASED'; status = 'PENDING'; requirement_ref = 'production/release-policy.md#production-released'
                requirement_digest = ('b' * 64); subject = [ordered]@{ source_sha = '5f41c4e25be6eb5a24f78bc794ca1d80a036087c'; github_run_id = 34242450515 }
                evidence_refs = @(); inherited = $false; inherited_from = ''; verified_at = ''
            }
        }
        semantic_sha256 = ('0' * 64)
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
    param([pscustomobject]$Fixture,[int]$LockTimeoutMilliseconds = 5000)
    return Invoke-ArthurTerminalReleaseReconcile `
        -StatusPath $Fixture.Paths.status `
        -KnownGoodPath $Fixture.Paths.known_good `
        -ReleaseEvidencePath $Fixture.Paths.release_evidence `
        -DeviceEvidencePath $Fixture.Paths.device_evidence `
        -ResumeStatePath $Fixture.Paths.resume `
        -OperatorIntentPath $Fixture.Paths.intent `
        -RuntimeStatePath $Fixture.Paths.runtime `
        -EventLogPath $Fixture.Paths.events `
        -ExecutionId $Fixture.TerminalExecutionId `
        -LockTimeoutMilliseconds $LockTimeoutMilliseconds
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
    Assert-Equal $resume.source.accepted_source_sha $identity.source_commit 'resume must use published production source identity'
    Assert-Equal $resume.production.candidate_sha256 $identity.sha256 'resume must use published production firmware identity'
    Assert-Equal $resume.gates.PRE_FLASH.status 'PASS' 'terminal reconciliation must close stale PRE_FLASH gate'
    Assert-Equal $resume.gates.PRODUCTION_RELEASED.status 'PASS' 'terminal reconciliation must pass terminal gate'
    $resumeForHash = $resume | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    [void]$resumeForHash.PSObject.Properties.Remove('semantic_sha256')
    Assert-Equal $resume.semantic_sha256 (Get-ArthurResumeSemanticHash $resumeForHash) 'resume semantic hash must cover the terminal snapshot'
    $nextGate = Get-ArthurNextRequiredGate -Gates @(Get-ArthurGateRecordsFromResumeState $resume) -GateOrder $script:ArthurResumePhaseOrder
    Assert-True ($null -eq $nextGate) 'terminalized gates must not reopen PRE_FLASH or another actionable gate'

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
. (Join-Path $Root 'scripts\arthur-resume-state.ps1')

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
    . $LedgerPath
    Assert-True (Test-ArthurFirmwareEventLedger -Path $forward.Paths.events) 'terminal reconciliation event log must retain hash-chain integrity'
    $forwardTerminalEvent = @(
        Get-ArthurFirmwareEvents -Path $forward.Paths.events |
            Where-Object {
                $_.event -eq 'PRODUCTION_RELEASED' -and
                [long]$_.data.run_id -eq $forward.Identity.run_id -and
                $_.data.stable_tag -eq $forward.Identity.stable_tag
            }
    ) | Select-Object -First 1
    Assert-True ($null -ne $forwardTerminalEvent) 'forward closure must record a terminal event'
    Assert-Equal $forwardTerminalEvent.source 'TERMINAL_RELEASE_RECONCILER' 'terminal event must identify the terminal reconciler source'

    # Break caught: a contended terminal reconciliation must not partially replace a
    # canonical state file or append a duplicate event before it owns the lock.
    $contendedDir = Join-Path $testRoot 'contended'
    New-Item -ItemType Directory -Path $contendedDir -Force | Out-Null
    $contended = New-TerminalReconcileFixture -Directory $contendedDir
    $contendedBefore = @{}
    foreach ($path in $contended.Paths.Values) { $contendedBefore[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
    $lockPath = "$($contended.Paths.events).terminal-release-reconcile.lock"
    $heldLock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $threw = $false
        $lockError = ''
        try { Invoke-TestReconcile $contended -LockTimeoutMilliseconds 20 | Out-Null } catch { $threw = $true; $lockError = $_.Exception.Message }
        Assert-True $threw 'contended terminal reconciliation must fail before any write'
        Assert-True ($lockError -match 'ARTHUR_TERMINAL_RECONCILE_LOCK_TIMEOUT') 'contended terminal reconciliation must fail because the transaction lock is held'
        foreach ($path in $contended.Paths.Values) { Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash $contendedBefore[$path] 'contended terminal reconciliation must not partially write state' }
    }
    finally { $heldLock.Dispose() }
    Invoke-TestReconcile $contended | Out-Null
    Assert-TerminalSnapshot $contended
    Assert-Equal (Get-TerminalEventCount -Path $contended.Paths.events -RunId $contended.Identity.run_id -StableTag $contended.Identity.stable_tag) 1 'retry after lock release must append exactly one terminal event'

    # Break caught: a retry that appends another terminal event or mutates a settled snapshot is not idempotent.
    $beforeResume = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.resume).Hash
    $beforeIntent = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.intent).Hash
    $beforeRuntime = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.runtime).Hash
    $beforeEvents = (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.events).Hash
    Invoke-TestReconcile $forward | Out-Null
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.resume).Hash $beforeResume 'second terminal reconciliation must not rewrite resume state'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.intent).Hash $beforeIntent 'second terminal reconciliation must not rewrite operator intent'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.runtime).Hash $beforeRuntime 'second terminal reconciliation must not rewrite runtime state'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $forward.Paths.events).Hash $beforeEvents 'second terminal reconciliation must not rewrite the event ledger'
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
    $beforeNewResume = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.resume).Hash
    $beforeNewIntent = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.intent).Hash
    $beforeNewRuntime = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.runtime).Hash
    $beforeNewEvents = (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.events).Hash
    $beforeNewTerminalEvents = Get-TerminalEventCount -Path $newExecution.Paths.events -RunId $newExecution.Identity.run_id -StableTag $newExecution.Identity.stable_tag
    Invoke-TestReconcile $newExecution | Out-Null
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.resume).Hash $beforeNewResume 'terminal reconcile must not close a distinct new execution resume state'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.intent).Hash $beforeNewIntent 'terminal reconcile must not close a distinct new execution intent'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.runtime).Hash $beforeNewRuntime 'terminal reconcile must not overwrite a distinct new execution runtime'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $newExecution.Paths.events).Hash $beforeNewEvents 'terminal reconcile must not mutate the event ledger for a distinct new execution'
    Assert-Equal (Get-TerminalEventCount -Path $newExecution.Paths.events -RunId $newExecution.Identity.run_id -StableTag $newExecution.Identity.stable_tag) $beforeNewTerminalEvents 'terminal reconcile must not append a terminal event for a distinct new execution'
    $newIntent = Read-TestJson $newExecution.Paths.intent
    Assert-Equal $newIntent.firmware_execution_authorized $true 'new execution remains independently eligible after prior terminal release'

    Write-Host 'ARTHUR_TERMINAL_RELEASE_RECONCILER_CONTRACT=PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
