Set-StrictMode -Version Latest

$FastSafeReleaseLib = Join-Path $PSScriptRoot 'fast-safe-release-lib.ps1'
if (-not (Test-Path -LiteralPath $FastSafeReleaseLib -PathType Leaf)) { throw "FAST_SAFE_RELEASE_LIB_MISSING=$FastSafeReleaseLib" }
. $FastSafeReleaseLib

$script:FeatureHandoffStages = @(
    'PREVIEW_ACCEPTED','LOCAL_CHANGES_CAPTURED','STATIC_VERIFIED','SOURCE_FROZEN',
    'REMOTE_INTEGRATED','BUILD_DISPATCHED','CONTROLLER_ATTACHED','PRODUCTION_RUNNING','PRODUCTION_RELEASED'
)

$script:FeatureHandoffProtectedExact = @(
    'config/required-plugins.txt','config/arthur.config','config/arthur-known-good.lock',
    'production/known-good.json','production/status.json','VERSION','build.env',
    'files/etc/config/wireless','files/etc/config/network'
)

$script:FeatureHandoffExcludedPrefixes = @('work/','output/','build_dir/','staging_dir/','dl/','tmp/')

function ConvertTo-HandoffPath([string]$Path) {
    return (($Path -replace '\\','/').Trim()).TrimStart('./')
}

function Get-FeatureHandoffKey([string]$FeatureId,[string]$AcceptedPreviewSourceSha) {
    if ($FeatureId -notmatch '^[a-z0-9][a-z0-9._-]{2,80}$') { throw 'FEATURE_HANDOFF_INVALID_FEATURE_ID' }
    if ($AcceptedPreviewSourceSha -notmatch '^[0-9a-f]{40}$') { throw 'FEATURE_HANDOFF_INVALID_ACCEPTED_SHA' }
    return "$FeatureId`:$AcceptedPreviewSourceSha"
}

function New-FeatureHandoffState {
    param(
        [Parameter(Mandatory)][string]$FeatureId,
        [Parameter(Mandatory)][string]$AcceptedPreviewSourceSha,
        [Parameter(Mandatory)][string]$AcceptedDiffSha256,
        [Parameter(Mandatory)][string]$PreviewManifestSha256,
        [Parameter(Mandatory)][string]$PreviewManifestPath,
        [Parameter(Mandatory)]$PreviewEvidence
    )
    if ($AcceptedDiffSha256 -notmatch '^[0-9a-f]{64}$') { throw 'FEATURE_HANDOFF_INVALID_DIFF_SHA256' }
    if ($PreviewManifestSha256 -notmatch '^[0-9a-f]{64}$') { throw 'FEATURE_HANDOFF_INVALID_MANIFEST_SHA256' }
    $releaseTaskId = "arthur:${FeatureId}:$AcceptedPreviewSourceSha"
    [pscustomobject][ordered]@{
        schema_version = 2
        release_task_id = $releaseTaskId
        device_id = 'jdcloud_re-ss-01'
        feature_id = $FeatureId
        dispatch_key = Get-FeatureHandoffKey -FeatureId $FeatureId -AcceptedPreviewSourceSha $AcceptedPreviewSourceSha
        accepted_preview_source_sha = $AcceptedPreviewSourceSha
        accepted_diff_sha256 = $AcceptedDiffSha256
        preview_manifest_sha256 = $PreviewManifestSha256
        preview_manifest_path = $PreviewManifestPath
        preview_evidence = $PreviewEvidence
        accepted_preview_fingerprint = ''
        build_fingerprint = ''
        active_run_id = 0
        artifact_sha256 = ''
        artifact_identity = ''
        flash_state = 'NOT_STARTED'
        next_action = ''
        invalidations = @()
        last_progress_at = (Get-Date).ToUniversalTime().ToString('o')
        last_progress_marker = 'PREVIEW_ACCEPTED'
        failure_fingerprint = ''
        terminal_state = 'ACTIVE'
        last_verified_stage = 'PREVIEW_ACCEPTED'
        executor_id = ''
        executor_state = 'IDLE'
        heartbeat_at = ''
        current_action = ''
        action_started_at = ''
        changed_paths = @()
        frozen_files = @()
        current_stage = 'PREVIEW_ACCEPTED'
        stage_status = 'VERIFIED'
        branch = ''
        feature_commit_sha = ''
        pr_number = 0
        merge_sha = ''
        dispatch_source_sha = ''
        selected_build_lane = ''
        v3_mode = ''
        dispatch_started_at = ''
        dispatch_accepted = $false
        dispatched_run_id = 0
        production_stage = ''
        suppress_dispatch = $false
        last_error = ''
        retry_count = 0
        created_at = (Get-Date).ToString('o')
        updated_at = (Get-Date).ToString('o')
    }
}

function Add-HandoffStateDefault($State,[string]$Name,$Value) {
    if ($State.PSObject.Properties.Name -notcontains $Name) {
        Add-Member -InputObject $State -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Complete-FeatureHandoffV2Defaults($State) {
    Add-HandoffStateDefault $State 'release_task_id' "arthur:$([string]$State.feature_id):$([string]$State.accepted_preview_source_sha)"
    Add-HandoffStateDefault $State 'device_id' 'jdcloud_re-ss-01'
    Add-HandoffStateDefault $State 'terminal_state' $(if ([string]$State.current_stage -eq 'PRODUCTION_RELEASED') { 'PRODUCTION_RELEASED' } else { 'ACTIVE' })
    Add-HandoffStateDefault $State 'last_verified_stage' $(if ([string]$State.stage_status -in @('VERIFIED','PASS')) { [string]$State.current_stage } else { 'PREVIEW_ACCEPTED' })
    Add-HandoffStateDefault $State 'accepted_preview_fingerprint' ''
    Add-HandoffStateDefault $State 'build_fingerprint' ''
    $runId = 0
    if ($State.PSObject.Properties.Name -contains 'dispatched_run_id') { $runId = [long]$State.dispatched_run_id }
    Add-HandoffStateDefault $State 'active_run_id' $runId
    Add-HandoffStateDefault $State 'artifact_sha256' ''
    Add-HandoffStateDefault $State 'artifact_identity' ''
    Add-HandoffStateDefault $State 'flash_state' 'NOT_STARTED'
    Add-HandoffStateDefault $State 'next_action' ''
    Add-HandoffStateDefault $State 'invalidations' @()
    Add-HandoffStateDefault $State 'last_progress_at' (Get-Date).ToUniversalTime().ToString('o')
    Add-HandoffStateDefault $State 'last_progress_marker' ([string]$State.current_stage)
    Add-HandoffStateDefault $State 'failure_fingerprint' ''
    Add-HandoffStateDefault $State 'executor_id' ''
    Add-HandoffStateDefault $State 'executor_state' 'IDLE'
    Add-HandoffStateDefault $State 'heartbeat_at' ''
    Add-HandoffStateDefault $State 'current_action' ''
    Add-HandoffStateDefault $State 'action_started_at' ''
    Add-HandoffStateDefault $State 'dispatch_started_at' ''
    Add-HandoffStateDefault $State 'dispatch_accepted' $false
    return $State
}

function Save-FeatureHandoffState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$StatePath)
    $dir = Split-Path -Parent $StatePath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ([int]$State.schema_version -eq 1) { $State = ConvertTo-ReleaseTaskStateV2 -State $State -DeviceId 'jdcloud_re-ss-01' }
    if ([int]$State.schema_version -ne 2) { throw "FEATURE_HANDOFF_STATE_SCHEMA_UNSUPPORTED=$($State.schema_version)" }
    Complete-FeatureHandoffV2Defaults $State | Out-Null
    $State.updated_at = (Get-Date).ToString('o')
    $tmp = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $StatePath
}

function Load-FeatureHandoffState {
    param([Parameter(Mandatory)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try { $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 40 }
    catch { throw "FEATURE_HANDOFF_STATE_INVALID: $($_.Exception.Message)" }
    $schema = [int]$state.schema_version
    if ($schema -eq 1) { $state = ConvertTo-ReleaseTaskStateV2 -State $state -DeviceId 'jdcloud_re-ss-01' }
    elseif ($schema -ne 2) { throw "FEATURE_HANDOFF_STATE_SCHEMA_UNSUPPORTED=$schema" }
    Complete-FeatureHandoffV2Defaults $state | Out-Null
    return $state
}

function Assert-HandoffResumeIdentity {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$FeatureId,
        [Parameter(Mandatory)][string]$AcceptedPreviewSourceSha,
        [Parameter(Mandatory)][string]$AcceptedDiffSha256,
        [Parameter(Mandatory)][string]$PreviewManifestSha256
    )
    $mismatches = New-Object System.Collections.Generic.List[string]
    if ([string]$State.feature_id -ne $FeatureId) { $mismatches.Add('feature_id') }
    if ([string]$State.accepted_preview_source_sha -ne $AcceptedPreviewSourceSha.ToLowerInvariant()) { $mismatches.Add('accepted_preview_source_sha') }
    if ([string]$State.accepted_diff_sha256 -ne $AcceptedDiffSha256.ToLowerInvariant()) { $mismatches.Add('accepted_diff_sha256') }
    if ([string]$State.preview_manifest_sha256 -ne $PreviewManifestSha256.ToLowerInvariant()) { $mismatches.Add('preview_manifest_sha256') }
    if ($mismatches.Count -gt 0) {
        throw "FEATURE_HANDOFF_SOURCE_IDENTITY_MISMATCH fields=$($mismatches -join ',')"
    }
    return $true
}

function Set-FeatureHandoffStage {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$Stage,[string]$Status='LIVE',[string]$Message='')
    if ($Stage -notin $script:FeatureHandoffStages) { throw "FEATURE_HANDOFF_UNKNOWN_STAGE=$Stage" }
    Complete-FeatureHandoffV2Defaults $State | Out-Null
    Assert-ReleaseStageTransition -State $State -NextStage $Stage | Out-Null
    $State.current_stage = $Stage
    $State.stage_status = $Status
    if ($Status -in @('VERIFIED','PASS')) {
        $State.last_verified_stage = $Stage
        $State.last_progress_marker = $Stage
        $State.last_progress_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($Stage -eq 'PRODUCTION_RELEASED') { $State.terminal_state = 'PRODUCTION_RELEASED' }
    if ($Message) { $State.last_error = $Message }
    $State.updated_at = (Get-Date).ToString('o')
    return $State
}

function Get-FirstIncompleteHandoffStage {
    param([Parameter(Mandatory)]$State)
    $idx = [array]::IndexOf($script:FeatureHandoffStages,[string]$State.current_stage)
    if ($idx -lt 0) { throw "FEATURE_HANDOFF_UNKNOWN_STAGE=$($State.current_stage)" }
    if ([string]$State.current_stage -eq 'PRODUCTION_RELEASED') { return 'PRODUCTION_RELEASED' }
    if ([string]$State.stage_status -in @('VERIFIED','PASS')) {
        return $script:FeatureHandoffStages[[Math]::Min($idx + 1,$script:FeatureHandoffStages.Count - 1)]
    }
    return [string]$State.current_stage
}

function Test-ProductionWriteInProgress([string]$Stage) {
    return $Stage -in @('FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY')
}

function Get-HandoffDispatchAction {
    param([Parameter(Mandatory)]$State,[string]$ProductionStage='')
    Complete-FeatureHandoffV2Defaults $State | Out-Null
    if (Test-ProductionWriteInProgress -Stage $ProductionStage) { return 'RECONCILE' }
    if ($ProductionStage -eq 'PRODUCTION_RELEASED') { return 'RECONCILE' }
    if ([long]$State.dispatched_run_id -gt 0 -or [long]$State.active_run_id -gt 0 -or $State.suppress_dispatch -eq $true) { return 'RECONCILE' }
    if ([string]$State.dispatch_started_at -or $State.dispatch_accepted -eq $true) { return 'DISCOVER' }
    return 'DISPATCH'
}

function Assert-FeatureChangedPathsSafe {
    param([Parameter(Mandatory)][string[]]$ChangedPaths)
    foreach ($raw in $ChangedPaths) {
        $path = ConvertTo-HandoffPath $raw
        if (-not $path -or $path.StartsWith('/') -or $path -match '^[A-Za-z]:' -or $path -match '(^|/)\.\.(/|$)') {
            throw "FEATURE_HANDOFF_FORBIDDEN_PATH=$raw"
        }
        if ($script:FeatureHandoffProtectedExact -contains $path) { throw "FEATURE_HANDOFF_PROTECTED_PATH=$path" }
        if ($path -match '^files/etc/config/(wireless|network|firewall|dhcp)(/|$)') { throw "FEATURE_HANDOFF_FROZEN_NETWORK_PATH=$path" }
    }
    return $true
}

function Get-FeatureChangedPaths {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $raw = @(& git -C $RepoRoot status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'FEATURE_HANDOFF_GIT_STATUS_FAILED' }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $raw) {
        $text = [string]$line
        if ($text.Length -lt 4) { continue }
        $path = $text.Substring(3).Trim().Trim('"')
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = ConvertTo-HandoffPath $path
        $excluded = $false
        foreach ($prefix in $script:FeatureHandoffExcludedPrefixes) {
            if ($path.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
        }
        if (-not $excluded -and $path) { $paths.Add($path) }
    }
    return @($paths | Sort-Object -Unique)
}

function Get-StringSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-WorktreeDiffSha256 {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $paths = @(Get-FeatureChangedPaths -RepoRoot $RepoRoot)
    Assert-FeatureChangedPathsSafe -ChangedPaths $paths | Out-Null
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in $paths) {
        $full = Join-Path $RepoRoot ($path -replace '/','\')
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
            $parts.Add("$path=$hash")
        } else { $parts.Add("$path=<deleted>") }
    }
    return Get-StringSha256 (($parts | Sort-Object) -join "`n")
}

function Resolve-ManifestLocalPath([string]$RepoRoot,[string]$ManifestPath,[string]$Local) {
    if ([System.IO.Path]::IsPathRooted($Local)) { $resolved = [System.IO.Path]::GetFullPath($Local) }
    else {
        $candidate = Join-Path $RepoRoot $Local
        if (Test-Path -LiteralPath $candidate) { $resolved = [System.IO.Path]::GetFullPath($candidate) }
        else { $resolved = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ManifestPath) $Local)) }
    }
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($rootFull,[System.StringComparison]::OrdinalIgnoreCase)) { throw "FEATURE_HANDOFF_MANIFEST_LOCAL_OUTSIDE_REPO=$Local" }
    return $resolved
}

function Get-PreviewManifestIdentity {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "FEATURE_HANDOFF_MANIFEST_MISSING=$ManifestPath" }
    try { $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 30 }
    catch { throw "FEATURE_HANDOFF_MANIFEST_INVALID: $($_.Exception.Message)" }
    $entries = @($manifest.entries)
    if ($entries.Count -eq 0) { throw 'FEATURE_HANDOFF_MANIFEST_EMPTY' }
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $remote = [string]$entry.remote
        if (-not $remote.StartsWith('/') -or $remote -match '(^|/)\.\.(/|$)') { throw "FEATURE_HANDOFF_MANIFEST_REMOTE_INVALID=$remote" }
        if ($remote -match '^/etc/config/(wireless|network|firewall|dhcp)(/|$)') { throw "FEATURE_HANDOFF_MANIFEST_REMOTE_FORBIDDEN=$remote" }
        $sourceField = ''
        if ($entry.PSObject.Properties.Name -contains 'source') { $sourceField = [string]$entry.source }
        elseif ($entry.PSObject.Properties.Name -contains 'local') { $sourceField = [string]$entry.local }
        if (-not $sourceField) { throw "FEATURE_HANDOFF_MANIFEST_SOURCE_MISSING remote=$remote" }
        $localPath = Resolve-ManifestLocalPath -RepoRoot $RepoRoot -ManifestPath $ManifestPath -Local $sourceField
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "FEATURE_HANDOFF_MANIFEST_LOCAL_MISSING=$localPath" }
        $normalized.Add([pscustomobject]@{
            source=$sourceField; local=$localPath; remote=$remote; mode=[string]$entry.mode;
            sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
        })
    }
    [pscustomobject]@{
        manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ManifestPath).Hash.ToLowerInvariant()
        entries = [object[]]$normalized.ToArray()
    }
}

function Freeze-PreviewManifestToOverlay {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$ManifestPath)
    $identity = Get-PreviewManifestIdentity -RepoRoot $RepoRoot -ManifestPath $ManifestPath
    $frozen = New-Object System.Collections.Generic.List[object]
    $isGit = $false
    & git -C $RepoRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) { $isGit = $true }
    foreach ($entry in @($identity.entries)) {
        $relative = 'files/' + ([string]$entry.remote).TrimStart('/')
        $dest = Join-Path $RepoRoot ($relative -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -Force -LiteralPath ([string]$entry.local) -Destination $dest
        $destHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLowerInvariant()
        if ($destHash -ne [string]$entry.sha256) { throw "FEATURE_HANDOFF_FREEZE_HASH_MISMATCH=$relative" }
        if ($isGit -and ([string]$entry.mode -match '^(0?7[0-7]{2}|[1357][0-7]{2})$')) {
            & git -C $RepoRoot update-index --add --chmod=+x -- $relative *> $null
            if ($LASTEXITCODE -ne 0) { throw "FEATURE_HANDOFF_EXECUTABLE_INDEX_FAILED=$relative" }
        }
        $frozen.Add([pscustomobject]@{ source=$entry.source; remote=$entry.remote; overlay=$relative; sha256=$destHash; mode=$entry.mode })
    }
    return [object[]]$frozen.ToArray()
}

function Write-AcceptedPreviewRecord {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][object[]]$FrozenFiles,[string[]]$DeferredAcceptance=@())
    $dir = Join-Path $RepoRoot 'production\accepted-preview'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ("$($State.feature_id).json")
    $record = [pscustomobject][ordered]@{
        schema_version=1; feature_id=[string]$State.feature_id;
        accepted_preview_source_sha=[string]$State.accepted_preview_source_sha;
        accepted_diff_sha256=[string]$State.accepted_diff_sha256;
        preview_manifest_sha256=[string]$State.preview_manifest_sha256;
        frozen_files=@($FrozenFiles); preview_evidence=$State.preview_evidence;
        deferred_acceptance=@($DeferredAcceptance); wifi_state='VERIFIED_FROZEN'; frozen_at=(Get-Date).ToString('o')
    }
    $fingerprint = Get-AcceptedPreviewFingerprint -AcceptedRecord $record
    Add-Member -InputObject $record -NotePropertyName accepted_preview_fingerprint -NotePropertyValue $fingerprint
    Complete-FeatureHandoffV2Defaults $State | Out-Null
    $State.accepted_preview_fingerprint = $fingerprint
    $State.frozen_files = @($FrozenFiles)
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Select-HandoffBuildPlan {
    param([Parameter(Mandatory)][string[]]$ChangedPaths,[switch]$KnownGoodLockChanged)
    if ($KnownGoodLockChanged -or ($ChangedPaths | Where-Object { (ConvertTo-HandoffPath $_) -eq 'config/arthur-known-good.lock' })) {
        throw 'FEATURE_HANDOFF_SOURCE_IDENTITY_UNPROVEN: KNOWN_GOOD lock change requires an explicit source-update flow.'
    }
    [pscustomobject]@{ selected_build_lane='V3_REBUILD_KNOWN_GOOD'; v3_mode='rebuild_known_good'; reason='source-lock-preserving accepted preview overlay; use existing production-integrated v3 Candidate lane' }
}

function Copy-HandoffStateObject($State) { return (($State | ConvertTo-Json -Depth 40) | ConvertFrom-Json -Depth 40) }

function Reconcile-ProductionState {
    param([Parameter(Mandatory)]$HandoffState,[Parameter(Mandatory)]$ProductionState)
    $state = Copy-HandoffStateObject $HandoffState
    Complete-FeatureHandoffV2Defaults $state | Out-Null
    $stage = [string]$ProductionState.stage
    $state.production_stage = $stage
    if (Test-ProductionWriteInProgress -Stage $stage) {
        $state.current_stage='PRODUCTION_RUNNING'; $state.stage_status='LIVE'; $state.suppress_dispatch=$true; $state.flash_state=$stage
    } elseif ($stage -eq 'PRODUCTION_RELEASED') {
        $state.current_stage='PRODUCTION_RELEASED'; $state.last_verified_stage='PRODUCTION_RELEASED'; $state.stage_status='VERIFIED'; $state.terminal_state='PRODUCTION_RELEASED'; $state.suppress_dispatch=$true
    } elseif ($stage) {
        if ([array]::IndexOf($script:FeatureHandoffStages,[string]$state.current_stage) -lt [array]::IndexOf($script:FeatureHandoffStages,'CONTROLLER_ATTACHED')) { $state.current_stage='CONTROLLER_ATTACHED' }
        $state.stage_status='LIVE'
    }
    return $state
}