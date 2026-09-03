Set-StrictMode -Version Latest

$script:FastSafeCheckpointOrder = @(
    'PREVIEW_ACCEPTED','LOCAL_CHANGES_CAPTURED','STATIC_VERIFIED','SOURCE_FROZEN',
    'REMOTE_INTEGRATED','BUILD_DISPATCHED','CONTROLLER_ATTACHED','PRODUCTION_RUNNING','PRODUCTION_RELEASED'
)

function Add-ReleaseStateDefault($State,[string]$Name,$Value) {
    if ($State.PSObject.Properties.Name -notcontains $Name) {
        Add-Member -InputObject $State -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-FastSafeReleasePolicy {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $path = Join-Path $root 'production/fast-safe-release-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "FAST_SAFE_RELEASE_POLICY_MISSING=$path"
    }
    try { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 30 }
    catch { throw "FAST_SAFE_RELEASE_POLICY_INVALID: $($_.Exception.Message)" }
}

function New-ReleaseTaskState {
    param(
        [Parameter(Mandatory)][string]$ReleaseTaskId,
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$CurrentStage
    )
    if ($CurrentStage -notin $script:FastSafeCheckpointOrder) {
        throw "FAST_SAFE_RELEASE_UNKNOWN_STAGE=$CurrentStage"
    }
    [pscustomobject][ordered]@{
        schema_version = 2
        release_task_id = $ReleaseTaskId
        device_id = $DeviceId
        current_stage = $CurrentStage
        last_verified_stage = $CurrentStage
        terminal_state = 'ACTIVE'
        accepted_preview_fingerprint = ''
        build_fingerprint = ''
        active_run_id = 0
        artifact_sha256 = ''
        artifact_identity = ''
        flash_state = 'NOT_STARTED'
        next_action = ''
        invalidations = @()
        last_progress_at = (Get-Date).ToUniversalTime().ToString('o')
        last_progress_marker = $CurrentStage
        failure_fingerprint = ''
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function ConvertTo-ReleaseTaskStateV2 {
    param(
        [Parameter(Mandatory)]$State,
        [string]$DeviceId = 'jdcloud_re-ss-01'
    )
    $copy = (($State | ConvertTo-Json -Depth 50) | ConvertFrom-Json -Depth 50)
    $version = 1
    if ($copy.PSObject.Properties.Name -contains 'schema_version') { $version = [int]$copy.schema_version }
    if ($version -notin @(1,2)) { throw "FAST_SAFE_RELEASE_STATE_SCHEMA_UNSUPPORTED=$version" }

    if ($version -eq 1) {
        $feature = if ($copy.PSObject.Properties.Name -contains 'feature_id') { [string]$copy.feature_id } else { 'release' }
        $source = if ($copy.PSObject.Properties.Name -contains 'accepted_preview_source_sha') { [string]$copy.accepted_preview_source_sha } else { '' }
        if (-not $source) { $source = 'unknown' }
        $copy.schema_version = 2
        Add-ReleaseStateDefault $copy 'release_task_id' "arthur:${feature}:$source"
        Add-ReleaseStateDefault $copy 'device_id' $DeviceId
    }

    Add-ReleaseStateDefault $copy 'release_task_id' 'arthur:release:unknown'
    Add-ReleaseStateDefault $copy 'device_id' $DeviceId
    Add-ReleaseStateDefault $copy 'last_verified_stage' ([string]$copy.current_stage)
    Add-ReleaseStateDefault $copy 'terminal_state' $(if ([string]$copy.current_stage -eq 'PRODUCTION_RELEASED') { 'PRODUCTION_RELEASED' } else { 'ACTIVE' })
    Add-ReleaseStateDefault $copy 'accepted_preview_fingerprint' ''
    Add-ReleaseStateDefault $copy 'build_fingerprint' ''
    $runId = 0
    if ($copy.PSObject.Properties.Name -contains 'dispatched_run_id') { $runId = [long]$copy.dispatched_run_id }
    Add-ReleaseStateDefault $copy 'active_run_id' $runId
    Add-ReleaseStateDefault $copy 'artifact_sha256' ''
    Add-ReleaseStateDefault $copy 'artifact_identity' ''
    Add-ReleaseStateDefault $copy 'flash_state' 'NOT_STARTED'
    Add-ReleaseStateDefault $copy 'next_action' ''
    Add-ReleaseStateDefault $copy 'invalidations' @()
    Add-ReleaseStateDefault $copy 'last_progress_at' (Get-Date).ToUniversalTime().ToString('o')
    Add-ReleaseStateDefault $copy 'last_progress_marker' ([string]$copy.current_stage)
    Add-ReleaseStateDefault $copy 'failure_fingerprint' ''
    Add-ReleaseStateDefault $copy 'updated_at' (Get-Date).ToUniversalTime().ToString('o')
    return $copy
}

function Add-ReleaseInvalidation {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Checkpoint,
        [Parameter(Mandatory)][string]$Reason,
        [string]$OldFingerprint = '',
        [string]$NewFingerprint = '',
        [Parameter(Mandatory)][string]$MinimumRepeatStage
    )
    if ($Checkpoint -notin $script:FastSafeCheckpointOrder) { throw "FAST_SAFE_RELEASE_UNKNOWN_CHECKPOINT=$Checkpoint" }
    if ($MinimumRepeatStage -notin $script:FastSafeCheckpointOrder) { throw "FAST_SAFE_RELEASE_UNKNOWN_REPEAT_STAGE=$MinimumRepeatStage" }
    Add-ReleaseStateDefault $State 'invalidations' @()
    $record = [pscustomobject][ordered]@{
        checkpoint = $Checkpoint
        reason = $Reason
        old_fingerprint = $OldFingerprint
        new_fingerprint = $NewFingerprint
        minimum_repeat_stage = $MinimumRepeatStage
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $State.invalidations = @($State.invalidations) + @($record)
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    return $record
}

function Test-CheckpointValid {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Checkpoint,
        [string]$Fingerprint = ''
    )
    Add-ReleaseStateDefault $State 'invalidations' @()
    foreach ($record in @($State.invalidations)) {
        if ([string]$record.checkpoint -ne $Checkpoint) { continue }
        if (-not $Fingerprint -or -not [string]$record.old_fingerprint -or [string]$record.old_fingerprint -eq $Fingerprint) {
            return $false
        }
    }
    return $true
}

function Assert-ReleaseStageTransition {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$NextStage
    )
    if ($NextStage -notin $script:FastSafeCheckpointOrder) { throw "FAST_SAFE_RELEASE_UNKNOWN_STAGE=$NextStage" }
    $current = [string]$State.current_stage
    if ($current -notin $script:FastSafeCheckpointOrder) { throw "FAST_SAFE_RELEASE_UNKNOWN_STAGE=$current" }
    $currentIndex = [array]::IndexOf($script:FastSafeCheckpointOrder,$current)
    $nextIndex = [array]::IndexOf($script:FastSafeCheckpointOrder,$NextStage)
    if ($nextIndex -ge $currentIndex) { return $true }

    Add-ReleaseStateDefault $State 'invalidations' @()
    foreach ($record in @($State.invalidations)) {
        $repeat = [string]$record.minimum_repeat_stage
        if ($repeat -notin $script:FastSafeCheckpointOrder) { continue }
        $repeatIndex = [array]::IndexOf($script:FastSafeCheckpointOrder,$repeat)
        $checkpointIndex = [array]::IndexOf($script:FastSafeCheckpointOrder,[string]$record.checkpoint)
        if ($repeatIndex -le $nextIndex -and $checkpointIndex -ge $nextIndex) { return $true }
    }
    throw "RELEASE_STAGE_REGRESSION_WITHOUT_INVALIDATION current=$current next=$NextStage"
}

function Get-MinimumInvalidationForImpact {
    param([Parameter(Mandatory)][string]$ImpactClass)
    switch ($ImpactClass) {
        'DOC_ONLY'            { return 'NONE' }
        'CONTROL_PLANE_ONLY'  { return 'CONTROL_EVIDENCE_ONLY' }
        'PREVIEW_BYTES'       { return 'PREVIEW_AND_DOWNSTREAM' }
        'FIRMWARE_INPUT'      { return 'BUILD_AND_DOWNSTREAM' }
        'DEVICE_WRITE_POLICY' { return 'PREFLASH_AND_DOWNSTREAM' }
        default { throw "FAST_SAFE_RELEASE_UNKNOWN_IMPACT_CLASS=$ImpactClass" }
    }
}

function Set-ReleaseProgress {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Marker,
        [string]$NextAction = ''
    )
    $State.last_progress_marker = $Marker
    $State.last_progress_at = (Get-Date).ToUniversalTime().ToString('o')
    $State.next_action = $NextAction
    $State.updated_at = $State.last_progress_at
    return $State
}

function Save-ReleaseTaskState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$StatePath)
    $dir = Split-Path -Parent $StatePath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $tmp = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $StatePath
}

function Load-ReleaseTaskState {
    param([Parameter(Mandatory)][string]$StatePath,[string]$DeviceId='jdcloud_re-ss-01')
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try { $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 50 }
    catch { throw "FAST_SAFE_RELEASE_STATE_INVALID: $($_.Exception.Message)" }
    return ConvertTo-ReleaseTaskStateV2 -State $state -DeviceId $DeviceId
}
