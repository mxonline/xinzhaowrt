Set-StrictMode -Version Latest

$ledgerPath = Join-Path $PSScriptRoot 'arthur-firmware-event-ledger.ps1'
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    throw 'ARTHUR_TERMINAL_RECONCILER_LEDGER_HELPER_MISSING'
}
. $ledgerPath
$resumeStateHelperPath = Join-Path $PSScriptRoot 'arthur-resume-state.ps1'
if (-not (Test-Path -LiteralPath $resumeStateHelperPath -PathType Leaf)) {
    throw 'ARTHUR_TERMINAL_RECONCILER_RESUME_HELPER_MISSING'
}
. $resumeStateHelperPath

function Get-ArthurTerminalMember {
    param([object]$Value,[Parameter(Mandatory=$true)][string]$Name)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Set-ArthurTerminalMember {
    param([Parameter(Mandatory=$true)][object]$Value,[Parameter(Mandatory=$true)][string]$Name,$MemberValue)

    if ($Value -is [System.Collections.IDictionary]) {
        $Value[$Name] = $MemberValue
        return
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $MemberValue
        return
    }
    $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $MemberValue
}

function Get-ArthurTerminalObjectMember {
    param([Parameter(Mandatory=$true)][object]$Value,[Parameter(Mandatory=$true)][string]$Name)

    $member = Get-ArthurTerminalMember $Value $Name
    if ($null -eq $member) {
        $member = [pscustomobject]@{}
        Set-ArthurTerminalMember $Value $Name $member
    }
    return $member
}

function Read-ArthurTerminalJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "ARTHUR_TERMINAL_EVIDENCE_MISSING=$Label" }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { throw "ARTHUR_TERMINAL_EVIDENCE_INVALID_JSON=$Label" }
}

function Get-ArthurTerminalIdentity {
    param([Parameter(Mandatory=$true)][object]$Evidence,[Parameter(Mandatory=$true)][string]$Label)

    $declaredRunText = [string](Get-ArthurTerminalMember $Evidence 'run_id')
    $toolchainRunText = [string](Get-ArthurTerminalMember $Evidence 'toolchain_run')
    $runText = $declaredRunText
    if ([string]::IsNullOrWhiteSpace($runText)) { $runText = $toolchainRunText }
    $runId = 0L
    if (-not [long]::TryParse($runText,[ref]$runId) -or $runId -le 0) { throw "ARTHUR_TERMINAL_IDENTITY_INVALID_RUN=$Label" }
    if (-not [string]::IsNullOrWhiteSpace($declaredRunText) -and -not [string]::IsNullOrWhiteSpace($toolchainRunText)) {
        $toolchainRunId = 0L
        if (-not [long]::TryParse($toolchainRunText,[ref]$toolchainRunId) -or $toolchainRunId -ne $runId) {
            throw "ARTHUR_TERMINAL_IDENTITY_RUN_CONFLICT=$Label"
        }
    }

    $identity = [ordered]@{
        run_id = $runId
        stable_tag = [string](Get-ArthurTerminalMember $Evidence 'stable_tag')
        project_commit = [string](Get-ArthurTerminalMember $Evidence 'project_commit')
        source_commit = [string](Get-ArthurTerminalMember $Evidence 'source_commit')
        firmware = [string](Get-ArthurTerminalMember $Evidence 'firmware')
        sha256 = [string](Get-ArthurTerminalMember $Evidence 'sha256')
    }
    foreach ($key in @('stable_tag','project_commit','source_commit','firmware','sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$identity[$key])) { throw "ARTHUR_TERMINAL_IDENTITY_MISSING=$Label/$key" }
    }
    if ($identity.project_commit -notmatch '^[0-9a-fA-F]{40}$' -or $identity.source_commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "ARTHUR_TERMINAL_IDENTITY_COMMIT_INVALID=$Label"
    }
    if ($identity.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "ARTHUR_TERMINAL_IDENTITY_SHA256_INVALID=$Label" }
    return [pscustomobject]$identity
}

function Assert-ArthurTerminalIdentityMatch {
    param([Parameter(Mandatory=$true)][object]$Expected,[Parameter(Mandatory=$true)][object]$Actual,[Parameter(Mandatory=$true)][string]$Label)

    foreach ($key in @('run_id','stable_tag','project_commit','source_commit','firmware','sha256')) {
        $expectedValue = [string](Get-ArthurTerminalMember $Expected $key)
        $actualValue = [string](Get-ArthurTerminalMember $Actual $key)
        if ($expectedValue -ne $actualValue) { throw "ARTHUR_TERMINAL_EVIDENCE_IDENTITY_MISMATCH=$Label/$key" }
    }
}

function Test-ArthurTerminalExecutionMatch {
    param([Parameter(Mandatory=$true)][string]$ExecutionId,[Parameter(Mandatory=$true)][object]$Resume,[Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][object]$Runtime)

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) { throw 'ARTHUR_TERMINAL_EXECUTION_ID_MISSING' }
    return (
        [string](Get-ArthurTerminalMember $Resume 'execution_id') -eq $ExecutionId -and
        [string](Get-ArthurTerminalMember $Intent 'execution_id') -eq $ExecutionId -and
        [string](Get-ArthurTerminalMember $Runtime 'execution_id') -eq $ExecutionId
    )
}

function Test-ArthurTerminalSnapshot {
    param([Parameter(Mandatory=$true)][object]$Resume,[Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][object]$Runtime,[Parameter(Mandatory=$true)][object]$Identity)

    $checkpoint = Get-ArthurTerminalMember $Resume 'checkpoint'
    $production = Get-ArthurTerminalMember $Resume 'production'
    $source = Get-ArthurTerminalMember $Resume 'source'
    $firmwareState = Get-ArthurTerminalMember $Intent 'firmware_state'
    $gates = @(Get-ArthurGateRecordsFromResumeState -ResumeState $Resume)
    $resumeForHash = $Resume | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    [void]$resumeForHash.PSObject.Properties.Remove('semantic_sha256')
    return (
        [string](Get-ArthurTerminalMember $Resume 'status') -eq 'PRODUCTION_RELEASED' -and
        (Get-ArthurTerminalMember $Resume 'instruction_allowed') -eq $false -and
        [string](Get-ArthurTerminalMember $Resume 'current_gate') -eq 'PRODUCTION_RELEASED' -and
        [string](Get-ArthurTerminalMember $Resume 'next_action') -eq 'NONE' -and
        @((Get-ArthurTerminalMember $Resume 'pending')).Count -eq 0 -and
        @((Get-ArthurTerminalMember $Resume 'conflicts')).Count -eq 0 -and
        [string](Get-ArthurTerminalMember $checkpoint 'current') -eq 'PRODUCTION_RELEASED' -and
        [string](Get-ArthurTerminalMember $checkpoint 'next_action') -eq 'NONE' -and
        [long](Get-ArthurTerminalMember $production 'github_run_id') -eq [long](Get-ArthurTerminalMember $Identity 'run_id') -and
        [string](Get-ArthurTerminalMember $source 'accepted_source_sha') -eq [string](Get-ArthurTerminalMember $Identity 'source_commit') -and
        [string](Get-ArthurTerminalMember $production 'candidate_sha256') -eq [string](Get-ArthurTerminalMember $Identity 'sha256') -and
        @($gates | Where-Object { [string](Get-ArthurTerminalMember $_ 'status') -ne 'PASS' }).Count -eq 0 -and
        [string](Get-ArthurTerminalMember $Resume 'semantic_sha256') -eq (Get-ArthurResumeSemanticHash -State $resumeForHash) -and
        (Get-ArthurTerminalMember $Intent 'firmware_execution_authorized') -eq $false -and
        [string](Get-ArthurTerminalMember $firmwareState 'current_stage') -eq 'PRODUCTION_RELEASED' -and
        [string](Get-ArthurTerminalMember $firmwareState 'next_stage') -eq 'NONE' -and
        [long](Get-ArthurTerminalMember $firmwareState 'active_run_id') -eq [long](Get-ArthurTerminalMember $Identity 'run_id') -and
        [string](Get-ArthurTerminalMember $firmwareState 'active_source_sha') -eq [string](Get-ArthurTerminalMember $Identity 'source_commit') -and
        [string](Get-ArthurTerminalMember $Runtime 'phase') -eq 'PRODUCTION_RELEASED' -and
        [string](Get-ArthurTerminalMember $Runtime 'current_stage') -eq 'PRODUCTION_RELEASED' -and
        [string](Get-ArthurTerminalMember $Runtime 'next_action') -eq 'NONE' -and
        [string](Get-ArthurTerminalMember $Runtime 'terminal_state') -eq 'PRODUCTION_RELEASED' -and
        $null -eq (Get-ArthurTerminalMember $Runtime 'pending_human_gate')
    )
}

function Write-ArthurTerminalJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 50
    [IO.File]::WriteAllText($Path,$json + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}

function Set-ArthurTerminalResumeSemanticHash {
    param([Parameter(Mandatory=$true)][object]$Resume)

    $property = $Resume.PSObject.Properties['semantic_sha256']
    if ($property) { [void]$Resume.PSObject.Properties.Remove('semantic_sha256') }
    $hash = Get-ArthurResumeSemanticHash -State $Resume
    Set-ArthurTerminalMember $Resume 'semantic_sha256' $hash
}

function Set-ArthurTerminalGates {
    param([Parameter(Mandatory=$true)][object]$Resume,[Parameter(Mandatory=$true)][object]$Identity)

    $gates = Get-ArthurTerminalMember $Resume 'gates'
    if ($null -eq $gates) { return }
    $evidenceRef = "terminal-release:$($Identity.run_id)/$($Identity.stable_tag)"
    $records = if ($gates -is [System.Collections.IDictionary]) { @($gates.Values) } else { @($gates.PSObject.Properties | ForEach-Object { $_.Value }) }
    foreach ($gate in $records) {
        if ($null -eq $gate) { continue }
        Set-ArthurTerminalMember $gate 'status' 'PASS'
        Set-ArthurTerminalMember $gate 'subject' ([ordered]@{ source_sha = $Identity.source_commit; github_run_id = $Identity.run_id })
        Set-ArthurTerminalMember $gate 'evidence_refs' @($evidenceRef)
        Set-ArthurTerminalMember $gate 'inherited' $false
        Set-ArthurTerminalMember $gate 'inherited_from' ''
        # Keep the terminal snapshot serialization-stable: PowerShell JSON reads
        # offset-bearing timestamps back as DateTime, which would change the
        # resume semantic hash on the next resolver load.
        Set-ArthurTerminalMember $gate 'verified_at' ''
    }
}

function Enter-ArthurTerminalReconcileLock {
    param([Parameter(Mandatory=$true)][string]$EventLogPath,[Parameter(Mandatory=$true)][int]$TimeoutMilliseconds)

    if ($TimeoutMilliseconds -lt 1) { throw 'ARTHUR_TERMINAL_RECONCILE_LOCK_TIMEOUT_INVALID' }
    $lockPath = "$EventLogPath.terminal-release-reconcile.lock"
    $parent = Split-Path -Parent $lockPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { throw 'ARTHUR_TERMINAL_RECONCILE_LOCK_DIRECTORY_MISSING' }
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try { return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 10 }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'ARTHUR_TERMINAL_RECONCILE_LOCK_TIMEOUT'
}

function New-ArthurTerminalStagedFile {
    param([Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][byte[]]$Bytes)

    $stagePath = "$Destination.terminal-release-reconcile.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllBytes($stagePath,$Bytes)
    return $stagePath
}

function Restore-ArthurTerminalFile {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][byte[]]$Bytes)

    $stagePath = New-ArthurTerminalStagedFile -Destination $Path -Bytes $Bytes
    try { Replace-ArthurTerminalFile -StagePath $stagePath -Destination $Path }
    finally { if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Force } }
}

function Replace-ArthurTerminalFile {
    param([Parameter(Mandatory=$true)][string]$StagePath,[Parameter(Mandatory=$true)][string]$Destination)

    $backupPath = "$Destination.terminal-release-reconcile.$([guid]::NewGuid().ToString('N')).bak"
    try { [IO.File]::Replace($StagePath,$Destination,$backupPath,$true) }
    finally { if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force } }
}

function Invoke-ArthurTerminalStateTransaction {
    param(
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$StateBytes,
        [Parameter(Mandatory=$true)][string]$EventLogPath,
        [Parameter(Mandatory=$true)][object]$Identity,
        [Parameter(Mandatory=$true)][bool]$AppendEvent
    )

    $originalStates = [ordered]@{}
    $stagedStates = [ordered]@{}
    $eventExisted = Test-Path -LiteralPath $EventLogPath -PathType Leaf
    $eventBytes = if ($eventExisted) { [IO.File]::ReadAllBytes($EventLogPath) } else { [byte[]]@() }
    try {
        foreach ($path in $StateBytes.Keys) {
            $originalStates[$path] = [IO.File]::ReadAllBytes($path)
            $stagedStates[$path] = New-ArthurTerminalStagedFile -Destination $path -Bytes $StateBytes[$path]
        }
        foreach ($path in @($StateBytes.Keys)) {
            Replace-ArthurTerminalFile -StagePath $stagedStates[$path] -Destination $path
        }
        if ($AppendEvent) {
            [void](Add-ArthurFirmwareEvent -Path $EventLogPath -Event 'PRODUCTION_RELEASED' -Stage 'PRODUCTION_RELEASED' -Source 'TERMINAL_RELEASE_RECONCILER' -Data ([ordered]@{ run_id = $Identity.run_id; stable_tag = $Identity.stable_tag }))
        }
    }
    catch {
        $failure = $_
        foreach ($path in $originalStates.Keys) { Restore-ArthurTerminalFile -Path $path -Bytes $originalStates[$path] }
        if ($eventExisted) {
            if (Test-Path -LiteralPath $EventLogPath) { Restore-ArthurTerminalFile -Path $EventLogPath -Bytes $eventBytes }
        }
        elseif (Test-Path -LiteralPath $EventLogPath) { Remove-Item -LiteralPath $EventLogPath -Force }
        throw $failure
    }
    finally {
        foreach ($stagePath in $stagedStates.Values) { if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Force } }
    }
}

function Invoke-ArthurTerminalReleaseReconcile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$StatusPath,
        [Parameter(Mandatory=$true)][string]$KnownGoodPath,
        [Parameter(Mandatory=$true)][string]$ReleaseEvidencePath,
        [Parameter(Mandatory=$true)][string]$DeviceEvidencePath,
        [Parameter(Mandatory=$true)][string]$ResumeStatePath,
        [Parameter(Mandatory=$true)][string]$OperatorIntentPath,
        [Parameter(Mandatory=$true)][string]$RuntimeStatePath,
        [Parameter(Mandatory=$true)][string]$EventLogPath,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [ValidateRange(1,60000)][int]$LockTimeoutMilliseconds = 5000
    )

    # Read and validate every source before changing even one canonical state file.
    $status = Read-ArthurTerminalJson -Path $StatusPath -Label 'status'
    $knownGood = Read-ArthurTerminalJson -Path $KnownGoodPath -Label 'known_good'
    $releaseEvidence = Read-ArthurTerminalJson -Path $ReleaseEvidencePath -Label 'github_release'
    $deviceEvidence = Read-ArthurTerminalJson -Path $DeviceEvidencePath -Label 'real_device'
    $resume = Read-ArthurTerminalJson -Path $ResumeStatePath -Label 'resume'
    $intent = Read-ArthurTerminalJson -Path $OperatorIntentPath -Label 'operator_intent'
    $runtime = Read-ArthurTerminalJson -Path $RuntimeStatePath -Label 'runtime'

    if ([string](Get-ArthurTerminalMember $status 'status') -ne 'PRODUCTION_RELEASED' -or (Get-ArthurTerminalMember $status 'known_good') -ne $true) {
        throw 'ARTHUR_TERMINAL_STATUS_NOT_PRODUCTION_RELEASED'
    }
    if ((Get-ArthurTerminalMember $knownGood 'known_good') -ne $true -or (Get-ArthurTerminalMember $knownGood 'verified') -ne $true -or [string](Get-ArthurTerminalMember $knownGood 'verification') -ne 'real-device-confirmed') {
        throw 'ARTHUR_TERMINAL_KNOWN_GOOD_NOT_VERIFIED'
    }
    if ((Get-ArthurTerminalMember $deviceEvidence 'known_good') -ne $true -or (Get-ArthurTerminalMember $deviceEvidence 'verified') -ne $true -or [string](Get-ArthurTerminalMember $deviceEvidence 'verification') -ne 'real-device-confirmed') {
        throw 'ARTHUR_TERMINAL_DEVICE_EVIDENCE_NOT_VERIFIED'
    }
    if ([string](Get-ArthurTerminalMember $releaseEvidence 'verified_by') -ne 'GITHUB_ACTIONS_GITHUB_TOKEN' -or (Get-ArthurTerminalMember $releaseEvidence 'release_exists') -ne $true -or (Get-ArthurTerminalMember $releaseEvidence 'draft') -ne $false -or (Get-ArthurTerminalMember $releaseEvidence 'prerelease') -ne $false) {
        throw 'ARTHUR_TERMINAL_GITHUB_RELEASE_NOT_VERIFIED'
    }

    $identity = Get-ArthurTerminalIdentity -Evidence $status -Label 'status'
    Assert-ArthurTerminalIdentityMatch -Expected $identity -Actual (Get-ArthurTerminalIdentity -Evidence $knownGood -Label 'known_good') -Label 'known_good'
    Assert-ArthurTerminalIdentityMatch -Expected $identity -Actual (Get-ArthurTerminalIdentity -Evidence $releaseEvidence -Label 'github_release') -Label 'github_release'
    Assert-ArthurTerminalIdentityMatch -Expected $identity -Actual (Get-ArthurTerminalIdentity -Evidence $deviceEvidence -Label 'real_device') -Label 'real_device'
    $knownGoodFirmwareFile = [string](Get-ArthurTerminalMember $knownGood 'firmware_file')
    if (-not [string]::IsNullOrWhiteSpace($knownGoodFirmwareFile) -and $knownGoodFirmwareFile -ne $identity.firmware) { throw 'ARTHUR_TERMINAL_EVIDENCE_IDENTITY_MISMATCH=known_good/firmware_file' }

    # A valid terminal release is historical evidence, not authority to close another execution.
    if (-not (Test-ArthurTerminalExecutionMatch -ExecutionId $ExecutionId -Resume $resume -Intent $intent -Runtime $runtime)) {
        return [pscustomobject]@{ reconciled = $false; reason = 'EXECUTION_ID_MISMATCH'; run_id = $identity.run_id; stable_tag = $identity.stable_tag }
    }

    $lock = Enter-ArthurTerminalReconcileLock -EventLogPath $EventLogPath -TimeoutMilliseconds $LockTimeoutMilliseconds
    try {
        # The lock covers duplicate detection through append, so a retry cannot race
        # another reconciler into a second terminal event.
        # Re-read mutable canonical state after acquiring ownership.  A waiting retry
        # may have loaded the pre-terminal snapshot before the first caller committed.
        $resume = Read-ArthurTerminalJson -Path $ResumeStatePath -Label 'resume'
        $intent = Read-ArthurTerminalJson -Path $OperatorIntentPath -Label 'operator_intent'
        $runtime = Read-ArthurTerminalJson -Path $RuntimeStatePath -Label 'runtime'
        if (-not (Test-ArthurTerminalExecutionMatch -ExecutionId $ExecutionId -Resume $resume -Intent $intent -Runtime $runtime)) {
            return [pscustomobject]@{ reconciled = $false; reason = 'EXECUTION_ID_MISMATCH'; run_id = $identity.run_id; stable_tag = $identity.stable_tag }
        }
        [void](Test-ArthurFirmwareEventLedger -Path $EventLogPath)
        $terminalEvents = @(Get-ArthurFirmwareEvents -Path $EventLogPath | Where-Object { $_.event -eq 'PRODUCTION_RELEASED' -and [long]$_.data.run_id -eq $identity.run_id -and [string]$_.data.stable_tag -eq $identity.stable_tag })
        if ($terminalEvents.Count -gt 1) { throw 'ARTHUR_TERMINAL_LEDGER_DUPLICATE_EVENT' }
        if ($terminalEvents.Count -eq 1 -and [string]$terminalEvents[0].source -ne 'TERMINAL_RELEASE_RECONCILER') { throw 'ARTHUR_TERMINAL_LEDGER_SOURCE_CONFLICT' }
        if ((Test-ArthurTerminalSnapshot -Resume $resume -Intent $intent -Runtime $runtime -Identity $identity) -and $terminalEvents.Count -eq 1) {
            return [pscustomobject]@{ reconciled = $false; reason = 'ALREADY_RECONCILED'; run_id = $identity.run_id; stable_tag = $identity.stable_tag }
        }

    $checkpoint = Get-ArthurTerminalObjectMember $resume 'checkpoint'
    $production = Get-ArthurTerminalObjectMember $resume 'production'
    Set-ArthurTerminalMember $resume 'status' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $resume 'instruction_allowed' $false
    Set-ArthurTerminalMember $resume 'current_gate' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $resume 'next_action' 'NONE'
    Set-ArthurTerminalMember $resume 'pending' @()
    Set-ArthurTerminalMember $resume 'conflicts' @()
    Set-ArthurTerminalMember $checkpoint 'current' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $checkpoint 'next_action' 'NONE'
    Set-ArthurTerminalMember $production 'github_run_id' $identity.run_id
    Set-ArthurTerminalMember (Get-ArthurTerminalObjectMember $resume 'source') 'accepted_source_sha' $identity.source_commit
    Set-ArthurTerminalMember $production 'candidate_sha256' $identity.sha256
    Set-ArthurTerminalGates -Resume $resume -Identity $identity
    Set-ArthurTerminalResumeSemanticHash -Resume $resume

    $firmwareState = Get-ArthurTerminalObjectMember $intent 'firmware_state'
    Set-ArthurTerminalMember $intent 'firmware_execution_authorized' $false
    Set-ArthurTerminalMember $firmwareState 'current_stage' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $firmwareState 'next_stage' 'NONE'
    Set-ArthurTerminalMember $firmwareState 'active_run_id' $identity.run_id
    Set-ArthurTerminalMember $firmwareState 'active_source_sha' $identity.source_commit

    Set-ArthurTerminalMember $runtime 'phase' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $runtime 'current_stage' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $runtime 'next_action' 'NONE'
    Set-ArthurTerminalMember $runtime 'terminal_state' 'PRODUCTION_RELEASED'
    Set-ArthurTerminalMember $runtime 'pending_human_gate' $null

        $stateBytes = [ordered]@{
            $ResumeStatePath = [Text.UTF8Encoding]::new($false).GetBytes(($resume | ConvertTo-Json -Depth 50) + [Environment]::NewLine)
            $OperatorIntentPath = [Text.UTF8Encoding]::new($false).GetBytes(($intent | ConvertTo-Json -Depth 50) + [Environment]::NewLine)
            $RuntimeStatePath = [Text.UTF8Encoding]::new($false).GetBytes(($runtime | ConvertTo-Json -Depth 50) + [Environment]::NewLine)
        }
        Invoke-ArthurTerminalStateTransaction -StateBytes $stateBytes -EventLogPath $EventLogPath -Identity $identity -AppendEvent ($terminalEvents.Count -eq 0)
        return [pscustomobject]@{ reconciled = $true; reason = 'PRODUCTION_RELEASED'; run_id = $identity.run_id; stable_tag = $identity.stable_tag }
    }
    finally { $lock.Dispose() }
}
