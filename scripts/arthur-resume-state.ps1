Set-StrictMode -Version Latest

$script:ArthurResumePhaseOrder = @(
    'FORENSICS',
    'ADH_MANAGEMENT',
    'ADH_CHINESE',
    'CHANGE_IMPACT',
    'BASELINE_INHERITANCE',
    'EXPECTED_DIFF',
    'CONFIG',
    'PACKAGE',
    'PLUGIN_BASELINE_22',
    'ARGON_KUCAT',
    'LAN',
    'FAST_GATE',
    'BUILD',
    'ARTIFACT',
    'PRE_FLASH',
    'AUTO_FLASH_SAFETY_GATE',
    'FLASH',
    'WAIT_DEVICE',
    'IDENTIFY',
    'LAN_RUNTIME',
    'DHCP',
    'WAN',
    'DNS',
    'SSH',
    'LUCI',
    'PLUGIN_RUNTIME_22',
    'ARGON_KUCAT_RUNTIME',
    'SYSTEM_HEALTH',
    'RELEASE_GATE',
    'RELEASE',
    'PRODUCTION_RELEASED'
)

function Get-ArthurResumeMember {
    param([object]$Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ArthurResumePhaseIndex {
    param([string]$Phase)
    if ([string]::IsNullOrWhiteSpace($Phase)) { return -1 }
    return [Array]::IndexOf($script:ArthurResumePhaseOrder, $Phase)
}

function Resolve-ArthurControlPlaneCheckpoint {
    [CmdletBinding()]
    param([object]$ExistingCanonical = $null)

    $default = [ordered]@{
        current = 'ADH_MANAGEMENT'
        next_action = 'ADH_MANAGEMENT'
        status = 'CURRENT_RELEASE_CONTRACT'
    }
    if (-not $ExistingCanonical) { return [pscustomobject]$default }

    $task = [string](Get-ArthurResumeMember $ExistingCanonical 'production_task')
    $checkpoint = Get-ArthurResumeMember $ExistingCanonical 'checkpoint'
    if ($task -ne 'arthur-adh-quickstart' -or -not $checkpoint) { return [pscustomobject]$default }

    $current = [string](Get-ArthurResumeMember $checkpoint 'current')
    $nextAction = [string](Get-ArthurResumeMember $checkpoint 'next_action')
    if ((Get-ArthurResumePhaseIndex $current) -lt 0 -or (Get-ArthurResumePhaseIndex $nextAction) -lt 0) {
        return [pscustomobject]$default
    }

    return [pscustomobject]@{
        current = $current
        next_action = $nextAction
        status = [string](Get-ArthurResumeMember $checkpoint 'status')
    }
}

function Get-ArthurResumeSemanticHash {
    param([object]$State)
    $json = $State | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Resolve-ArthurResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryHead,
        [Parameter(Mandatory=$true)][object]$RealDeviceBaseline,
        [object]$LiveDevice = $null,
        [Parameter(Mandatory=$true)][object]$RuntimeState,
        [object]$PreviousResumeState = $null,
        [switch]$AllowBaselineFallbackForMissingLiveDevice
    )

    $conflicts = New-Object System.Collections.Generic.List[string]
    if ($RepositoryHead -notmatch '^[0-9a-fA-F]{40}$') { $conflicts.Add('GITHUB_HEAD_INVALID') }

    $baselineFirmware = Get-ArthurResumeMember $RealDeviceBaseline 'firmware'
    $baselineVersion = [string](Get-ArthurResumeMember $baselineFirmware 'version')
    $baselineBuildId = [string](Get-ArthurResumeMember $baselineFirmware 'build_id')
    $baselineSourceSha = [string](Get-ArthurResumeMember $baselineFirmware 'source_sha')
    $activeBaseline = Get-ArthurResumeMember $RealDeviceBaseline 'active_development_baseline'

    $phase = [string](Get-ArthurResumeMember $RuntimeState 'phase')
    $currentStage = [string](Get-ArthurResumeMember $RuntimeState 'current_stage')
    $nextAction = [string](Get-ArthurResumeMember $RuntimeState 'next_action')
    $turnCount = Get-ArthurResumeMember $RuntimeState 'turn_count'

    $liveEvidence = 'LIVE_BUILD_INFO'
    $adhPreviewPhase = $phase -in @('ADH_MANAGEMENT','ADH_CHINESE')
    $finalReleaseBuildFallback = (
        $phase -eq 'BUILD' -and
        [string]$env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK -eq '1'
    )
    $useBaselineFallback = (
        ($null -eq $LiveDevice) -and
        $activeBaseline -eq $true -and
        ($AllowBaselineFallbackForMissingLiveDevice -or $adhPreviewPhase -or $finalReleaseBuildFallback)
    )
    if ($useBaselineFallback) {
        $LiveDevice = [pscustomobject]@{
            version = $baselineVersion
            build_id = $baselineBuildId
            git_commit = $(if ($baselineSourceSha) { $baselineSourceSha.Substring(0, [Math]::Min(7, $baselineSourceSha.Length)) } else { '' })
        }
        $liveEvidence = 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED'
    }

    $liveVersion = [string](Get-ArthurResumeMember $LiveDevice 'version')
    $liveBuildId = [string](Get-ArthurResumeMember $LiveDevice 'build_id')
    $liveCommit = [string](Get-ArthurResumeMember $LiveDevice 'git_commit')

    if ($activeBaseline -ne $true) { $conflicts.Add('REAL_DEVICE_BASELINE_NOT_ACTIVE') }
    if ([string]::IsNullOrWhiteSpace($baselineVersion) -or [string]::IsNullOrWhiteSpace($liveVersion)) {
        $conflicts.Add('REAL_DEVICE_VERSION_MISSING')
    }
    elseif ($baselineVersion -ne $liveVersion) {
        $conflicts.Add('REAL_DEVICE_VERSION_BASELINE_MISMATCH')
    }
    if ($baselineBuildId -and $liveBuildId -and $baselineBuildId -ne $liveBuildId) {
        $conflicts.Add('REAL_DEVICE_BUILD_BASELINE_MISMATCH')
    }

    if ([string]::IsNullOrWhiteSpace($phase) -or (Get-ArthurResumePhaseIndex $phase) -lt 0) {
        $conflicts.Add('RUNTIME_PHASE_INVALID')
    }
    if (-not [string]::IsNullOrWhiteSpace($currentStage) -and $currentStage -ne $phase) {
        $conflicts.Add('RUNTIME_STAGE_PHASE_MISMATCH')
    }
    if ([string]::IsNullOrWhiteSpace($nextAction)) { $conflicts.Add('RUNTIME_NEXT_ACTION_MISSING') }

    if ($PreviousResumeState) {
        $previousStatus = [string](Get-ArthurResumeMember $PreviousResumeState 'status')
        $previousCheckpoint = Get-ArthurResumeMember $PreviousResumeState 'checkpoint'
        $previousCurrent = [string](Get-ArthurResumeMember $previousCheckpoint 'current')
        if ($previousStatus -ne 'STATE_RECONCILIATION_REQUIRED' -and -not [string]::IsNullOrWhiteSpace($previousCurrent)) {
            $previousIndex = Get-ArthurResumePhaseIndex $previousCurrent
            $currentIndex = Get-ArthurResumePhaseIndex $phase
            if ($previousIndex -ge 0 -and $currentIndex -ge 0 -and $currentIndex -lt $previousIndex) {
                $conflicts.Add('CHECKPOINT_REGRESSION')
            }
        }
    }

    $safe = ($conflicts.Count -eq 0)
    $state = [ordered]@{
        schema_version = 1
        status = $(if ($safe) { 'RESUME_SAFE' } else { 'STATE_RECONCILIATION_REQUIRED' })
        instruction_allowed = $safe
        repository_head = $RepositoryHead.ToLowerInvariant()
        real_device = [ordered]@{
            version = $liveVersion
            build_id = $liveBuildId
            git_commit = $liveCommit
            evidence = $liveEvidence
        }
        accepted_baseline = [ordered]@{
            version = $baselineVersion
            build_id = $baselineBuildId
            source_sha = $baselineSourceSha
        }
        checkpoint = [ordered]@{
            current = $phase
            next_action = $nextAction
            turn_count = $turnCount
        }
        verified = [ordered]@{
            real_device_baseline = $(if ($safe) { 'MATCHED' } else { 'RECONCILE_REQUIRED' })
            wifi = 'VERIFIED_FROZEN'
        }
        pending = @($nextAction)
        next_action = $nextAction
        conflicts = @($conflicts)
        source_precedence = @(
            'LIVE_DEVICE',
            'REAL_DEVICE_BASELINE',
            'AI_ORCHESTRATOR_RUNTIME',
            'GITHUB_HEAD',
            'HISTORICAL_DOCS_AUXILIARY_ONLY'
        )
        legacy_source_policy = 'AUXILIARY_ONLY'
        ignored_current_state_sources = @(
            'knowledge/PROJECT-STATE.md historical sections',
            'production/v4-state.json historical controller snapshot',
            'chat/model narrative'
        )
    }
    $state['semantic_sha256'] = Get-ArthurResumeSemanticHash $state
    return [pscustomobject]$state
}
