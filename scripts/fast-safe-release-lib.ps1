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

function Get-Sha256HexFromText {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-AcceptedPreviewFingerprint {
    param(
        [Parameter(Mandatory)]$AcceptedRecord,
        [string]$PreviewPolicyIdentity = ''
    )
    $required = @('feature_id','accepted_preview_source_sha','accepted_diff_sha256','preview_manifest_sha256','frozen_files')
    foreach ($name in $required) {
        if ($AcceptedRecord.PSObject.Properties.Name -notcontains $name) { throw "FAST_SAFE_RELEASE_PREVIEW_RECORD_MISSING=$name" }
    }
    $source = [string]$AcceptedRecord.accepted_preview_source_sha
    $diff = [string]$AcceptedRecord.accepted_diff_sha256
    $manifest = [string]$AcceptedRecord.preview_manifest_sha256
    if ($source -notmatch '^[0-9a-fA-F]{40}$') { throw 'FAST_SAFE_RELEASE_PREVIEW_SOURCE_SHA_INVALID' }
    if ($diff -notmatch '^[0-9a-fA-F]{64}$') { throw 'FAST_SAFE_RELEASE_PREVIEW_DIFF_SHA_INVALID' }
    if ($manifest -notmatch '^[0-9a-fA-F]{64}$') { throw 'FAST_SAFE_RELEASE_PREVIEW_MANIFEST_SHA_INVALID' }
    if (-not $PreviewPolicyIdentity) {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $policyPath = Join-Path $root 'production/live-preview-policy.json'
        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { throw 'FAST_SAFE_RELEASE_PREVIEW_POLICY_MISSING' }
        $PreviewPolicyIdentity = (Get-FileHash -Algorithm SHA256 -LiteralPath $policyPath).Hash.ToLowerInvariant()
    }
    $files = @($AcceptedRecord.frozen_files)
    if ($files.Count -eq 0) { throw 'FAST_SAFE_RELEASE_PREVIEW_RECORD_EMPTY' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("feature=$([string]$AcceptedRecord.feature_id)")
    $lines.Add("source=$($source.ToLowerInvariant())")
    $lines.Add("diff=$($diff.ToLowerInvariant())")
    $lines.Add("manifest=$($manifest.ToLowerInvariant())")
    $lines.Add("policy=$PreviewPolicyIdentity")
    foreach ($file in @($files | Sort-Object { [string]$_.remote })) {
        $remote = [string]$file.remote
        $hash = [string]$file.sha256
        $mode = [string]$file.mode
        if (-not $remote.StartsWith('/')) { throw "FAST_SAFE_RELEASE_PREVIEW_REMOTE_INVALID=$remote" }
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw "FAST_SAFE_RELEASE_PREVIEW_FILE_SHA_INVALID=$remote" }
        if (-not $mode) { throw "FAST_SAFE_RELEASE_PREVIEW_MODE_MISSING=$remote" }
        $lines.Add("file=$remote|$($hash.ToLowerInvariant())|$mode")
    }
    return Get-Sha256HexFromText -Text (($lines.ToArray()) -join "`n")
}

function Get-PreviewReuseDecision {
    param(
        [Parameter(Mandatory)]$AcceptedRecord,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DeviceHashes,
        [string]$PreviewPolicyIdentity = ''
    )
    try {
        $fingerprint = Get-AcceptedPreviewFingerprint -AcceptedRecord $AcceptedRecord -PreviewPolicyIdentity $PreviewPolicyIdentity
    } catch {
        return [pscustomobject][ordered]@{
            action = 'INVALIDATE_PREVIEW'
            reason = $_.Exception.Message
            fingerprint = ''
            paths = @()
            source_discovery_allowed = $true
            full_preview_deploy_allowed = $true
        }
    }
    $drifted = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($AcceptedRecord.frozen_files | Sort-Object { [string]$_.remote })) {
        $remote = [string]$file.remote
        $expected = ([string]$file.sha256).ToLowerInvariant()
        $has = $DeviceHashes.Contains($remote)
        $actual = if ($has) { ([string]$DeviceHashes[$remote]).ToLowerInvariant() } else { '' }
        if (-not $has -or $actual -ne $expected) { $drifted.Add($remote) }
    }
    if ($drifted.Count -eq 0) {
        return [pscustomobject][ordered]@{
            action = 'REUSE_PREVIEW_ACCEPTED'
            reason = 'accepted fingerprint and all target hashes match'
            fingerprint = $fingerprint
            paths = @()
            source_discovery_allowed = $false
            full_preview_deploy_allowed = $false
        }
    }
    return [pscustomobject][ordered]@{
        action = 'RESTORE_DRIFTED_PREVIEW_FILES'
        reason = 'accepted fingerprint is reusable; target file drift requires minimum restore'
        fingerprint = $fingerprint
        paths = @($drifted.ToArray())
        source_discovery_allowed = $false
        full_preview_deploy_allowed = $false
    }
}

function Get-BuildFingerprint {
    param([Parameter(Mandatory)]$InputIdentity)
    $required = @(
        'target','subtarget','profile','source_lock_sha256','toolchain_identity','config_sha256',
        'required_plugins_sha256','files_identity','build_scripts_identity','package_inputs_identity','theme_identity'
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        if ($InputIdentity.PSObject.Properties.Name -notcontains $name) { throw "FAST_SAFE_RELEASE_BUILD_IDENTITY_MISSING=$name" }
        $value = [string]$InputIdentity.$name
        if (-not $value) { throw "FAST_SAFE_RELEASE_BUILD_IDENTITY_EMPTY=$name" }
        if ($name -match '_sha256$|_identity$' -and $name -ne 'toolchain_identity') {
            if ($value -notmatch '^[0-9a-fA-F]{64}$') { throw "FAST_SAFE_RELEASE_BUILD_IDENTITY_INVALID=$name" }
            $value = $value.ToLowerInvariant()
        }
        $lines.Add("$name=$value")
    }
    return Get-Sha256HexFromText -Text (($lines.ToArray()) -join "`n")
}

function Get-BuildReuseDecision {
    param(
        [Parameter(Mandatory)][string]$BuildFingerprint,
        [object[]]$Runs = @(),
        [object[]]$Artifacts = @()
    )
    if ($BuildFingerprint -notmatch '^[0-9a-f]{64}$') { throw 'FAST_SAFE_RELEASE_BUILD_FINGERPRINT_INVALID' }
    $activeStatuses = @('queued','in_progress','waiting','requested','pending')
    foreach ($run in @($Runs)) {
        if ([string]$run.fingerprint -ne $BuildFingerprint) { continue }
        if ([string]$run.status -in $activeStatuses) {
            return [pscustomobject][ordered]@{
                action='WATCH_EXISTING_RUN'; run_id=[long]$run.id; build_fingerprint=$BuildFingerprint;
                artifact_sha256=''; artifact_identity=''
            }
        }
    }
    foreach ($artifact in @($Artifacts)) {
        if ([string]$artifact.fingerprint -ne $BuildFingerprint) { continue }
        if ($artifact.immutable -ne $true) { continue }
        $sha = [string]$artifact.sha256
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { continue }
        $acceptance = [string]$artifact.acceptance
        $identity = [string]$artifact.identity
        if ($acceptance -eq 'PASS') {
            return [pscustomobject][ordered]@{
                action='REUSE_ARTIFACT'; run_id=0; build_fingerprint=$BuildFingerprint;
                artifact_sha256=$sha.ToLowerInvariant(); artifact_identity=$identity
            }
        }
        if ($acceptance -in @('CONTROL_ONLY_FAIL','CONTROL_OR_ACCEPTANCE_ONLY','PENDING')) {
            return [pscustomobject][ordered]@{
                action='REVALIDATE_QUARANTINE_CANDIDATE'; run_id=0; build_fingerprint=$BuildFingerprint;
                artifact_sha256=$sha.ToLowerInvariant(); artifact_identity=$identity
            }
        }
    }
    return [pscustomobject][ordered]@{
        action='START_NEW_CANDIDATE'; run_id=0; build_fingerprint=$BuildFingerprint;
        artifact_sha256=''; artifact_identity=''
    }
}

function Write-CandidateQuarantineRecord {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record)
    $required = @('build_fingerprint','run_id','source_sha','artifact_name','artifact_sha256','target','profile','acceptance_class')
    foreach ($name in $required) {
        if ($Record.PSObject.Properties.Name -notcontains $name -or -not [string]$Record.$name) {
            throw "FAST_SAFE_RELEASE_QUARANTINE_FIELD_MISSING=$name"
        }
    }
    if ([string]$Record.build_fingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'FAST_SAFE_RELEASE_QUARANTINE_BUILD_FINGERPRINT_INVALID' }
    if ([string]$Record.source_sha -notmatch '^[0-9a-fA-F]{40}$') { throw 'FAST_SAFE_RELEASE_QUARANTINE_SOURCE_SHA_INVALID' }
    if ([string]$Record.artifact_sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'FAST_SAFE_RELEASE_QUARANTINE_ARTIFACT_SHA_INVALID' }
    if ([long]$Record.run_id -le 0) { throw 'FAST_SAFE_RELEASE_QUARANTINE_RUN_ID_INVALID' }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $normalized = [pscustomobject][ordered]@{
        schema_version=1
        build_fingerprint=([string]$Record.build_fingerprint).ToLowerInvariant()
        run_id=[long]$Record.run_id
        source_sha=([string]$Record.source_sha).ToLowerInvariant()
        artifact_name=[string]$Record.artifact_name
        artifact_sha256=([string]$Record.artifact_sha256).ToLowerInvariant()
        target=[string]$Record.target
        profile=[string]$Record.profile
        acceptance_class=[string]$Record.acceptance_class
        quarantined_at=(Get-Date).ToUniversalTime().ToString('o')
    }
    $tmp = "$Path.tmp"
    $normalized | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $Path
    return $normalized
}

function Get-CandidateQuarantineRecord {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $record = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 20 }
    catch { throw "FAST_SAFE_RELEASE_QUARANTINE_INVALID: $($_.Exception.Message)" }
    if ([int]$record.schema_version -ne 1) { throw "FAST_SAFE_RELEASE_QUARANTINE_SCHEMA_UNSUPPORTED=$($record.schema_version)" }
    if ([string]$record.build_fingerprint -notmatch '^[0-9a-f]{64}$') { throw 'FAST_SAFE_RELEASE_QUARANTINE_BUILD_FINGERPRINT_INVALID' }
    if ([string]$record.artifact_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'FAST_SAFE_RELEASE_QUARANTINE_ARTIFACT_SHA_INVALID' }
    return $record
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