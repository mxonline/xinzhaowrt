Set-StrictMode -Version Latest

$stateContractPath = Join-Path $PSScriptRoot 'arthur-state-contract.ps1'
if (-not (Test-Path -LiteralPath $stateContractPath -PathType Leaf)) {
    throw 'ARTHUR_RESUME_STATE_CONTRACT_MISSING'
}
. $stateContractPath

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

function Get-ArthurResumeMapValue {
    param([object]$Map,[string]$Name)
    return (Get-ArthurResumeMember $Map $Name)
}

function Get-ArthurResumePhaseIndex {
    param([string]$Phase)
    if ([string]::IsNullOrWhiteSpace($Phase)) { return -1 }
    return [Array]::IndexOf($script:ArthurResumePhaseOrder, $Phase)
}

function Get-ArthurGateRecordsFromResumeState {
    [CmdletBinding()]
    param([object]$ResumeState = $null)

    if ($null -eq $ResumeState) { return @() }
    $gates = Get-ArthurResumeMember $ResumeState 'gates'
    if ($null -eq $gates) { return @() }

    $records = @()
    if ($gates -is [System.Collections.IDictionary]) {
        foreach ($key in $gates.Keys) {
            if ($null -ne $gates[$key]) { $records += $gates[$key] }
        }
    }
    else {
        foreach ($property in @($gates.PSObject.Properties)) {
            if ($null -ne $property.Value) { $records += $property.Value }
        }
    }
    return @($records)
}

function Get-ArthurCurrentSubjectsForRepositoryHead {
    [CmdletBinding()]
    param(
        [object[]]$GateRecords = @(),
        [Parameter(Mandatory=$true)][string]$RepositoryHead
    )

    $head = $RepositoryHead.Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "ARTHUR_CURRENT_SUBJECT_REPOSITORY_HEAD_INVALID=$RepositoryHead" }

    $subjects = [ordered]@{}
    foreach ($gate in @($GateRecords)) {
        if ($null -eq $gate) { continue }
        $gateId = [string](Get-ArthurResumeMember $gate 'gate_id')
        if ([string]::IsNullOrWhiteSpace($gateId)) { throw 'ARTHUR_CURRENT_SUBJECT_GATE_ID_MISSING' }
        $sourceSubject = Get-ArthurResumeMember $gate 'subject'
        $copy = [ordered]@{}
        if ($sourceSubject -is [System.Collections.IDictionary]) {
            foreach ($key in $sourceSubject.Keys) { $copy[[string]$key] = $sourceSubject[$key] }
        }
        elseif ($null -ne $sourceSubject) {
            foreach ($property in @($sourceSubject.PSObject.Properties)) { $copy[[string]$property.Name] = $property.Value }
        }

        $inherited = [bool](Get-ArthurResumeMember $gate 'inherited')
        if (-not $inherited -and $copy.Contains('source_sha')) { $copy['source_sha'] = $head }
        $subjects[$gateId] = [pscustomobject]$copy
    }
    return [pscustomobject]$subjects
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

function ConvertTo-ArthurResumeHashCanonicalValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $utcTimestamp = $null
    if ($Value -is [DateTimeOffset]) {
        $utcTimestamp = $Value.UtcDateTime
    }
    elseif ($Value -is [DateTime]) {
        $utcTimestamp = if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        else {
            $Value.ToUniversalTime()
        }
    }
    if ($null -ne $utcTimestamp) {
        return $utcTimestamp.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $canonical = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $canonical[$key] = ConvertTo-ArthurResumeHashCanonicalValue -Value $Value[$key]
        }
        return ,$canonical
    }

    if ($Value -is [pscustomobject]) {
        $canonical = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $canonical[$property.Name] = ConvertTo-ArthurResumeHashCanonicalValue -Value $property.Value
        }
        return ,$canonical
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $canonical = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $canonical.Add((ConvertTo-ArthurResumeHashCanonicalValue -Value $item))
        }
        return ,$canonical.ToArray()
    }

    return $Value
}

function Get-ArthurResumeSemanticHash {
    param([object]$State)
    $canonicalState = ConvertTo-ArthurResumeHashCanonicalValue -Value $State
    $json = $canonicalState | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Convert-ArthurLegacyTerminalResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Legacy,
        [Parameter(Mandatory=$true)][object]$Status,
        [Parameter(Mandatory=$true)][object]$ProductGoalVerification,
        [Parameter(Mandatory=$true)][object]$KnownGood,
        [Parameter(Mandatory=$true)][object]$WifiBaseline,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$RepositoryHead
    )

    if ([int](Get-ArthurResumeMember $Legacy 'schema_version') -ne 1 -or
        [string](Get-ArthurResumeMember $Legacy 'status') -ne 'PRODUCTION_RELEASED' -or
        [string](Get-ArthurResumeMember $Legacy 'NEXT_ACTION') -ne 'NONE') {
        throw 'ARTHUR_LEGACY_TERMINAL_SNAPSHOT_INVALID'
    }
    if ($RepositoryHead -notmatch '^[0-9a-fA-F]{40}$') { throw 'ARTHUR_LEGACY_TERMINAL_REPOSITORY_HEAD_INVALID' }
    $wifiPolicy = Get-ArthurResumeMember $WifiBaseline 'policy'
    $wifiSourceRelative = [string](Get-ArthurResumeMember $WifiBaseline 'source_path')
    $wifiSourceBlob = [string](Get-ArthurResumeMember $WifiBaseline 'source_git_blob_sha')
    if ([string](Get-ArthurResumeMember $WifiBaseline 'status') -ne 'VERIFIED_FROZEN' -or
        $wifiSourceRelative -ne 'files/etc/uci-defaults/98-xinzhao-wifi-defaults' -or
        $wifiSourceBlob -notmatch '^[0-9a-fA-F]{40}$' -or
        (Get-ArthurResumeMember $wifiPolicy 'runtime_revalidation_required_for_prebuild') -ne $false -or
        (Get-ArthurResumeMember $wifiPolicy 'runtime_mutation_forbidden') -ne $true -or
        (Get-ArthurResumeMember $wifiPolicy 'wifi_reload_forbidden') -ne $true) {
        throw 'ARTHUR_LEGACY_TERMINAL_WIFI_BASELINE_INVALID'
    }
    $wifiSourcePath = Join-Path $RepositoryRoot ($wifiSourceRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $wifiSourcePath -PathType Leaf)) { throw 'ARTHUR_LEGACY_TERMINAL_WIFI_SOURCE_MISSING' }
    $actualWifiSourceBlob = (& git -C $RepositoryRoot hash-object -- $wifiSourceRelative 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualWifiSourceBlob -ne $wifiSourceBlob) { throw 'ARTHUR_LEGACY_TERMINAL_WIFI_SOURCE_HASH_MISMATCH' }
    $legacySource = Get-ArthurResumeMember $Legacy 'source'
    $legacyArtifact = Get-ArthurResumeMember $Legacy 'artifact'
    $legacyDevice = Get-ArthurResumeMember $Legacy 'device'
    $sourceSha = [string](Get-ArthurResumeMember $legacySource 'source_sha')
    $runId = [string](Get-ArthurResumeMember $legacySource 'build_run_id')
    $artifactId = [string](Get-ArthurResumeMember $legacySource 'artifact_id')
    $stableTag = [string](Get-ArthurResumeMember $legacySource 'stable_tag')
    $firmwareSha = [string](Get-ArthurResumeMember $legacyArtifact 'sysupgrade_sha256')
    $firmware = [string](Get-ArthurResumeMember $legacyArtifact 'sysupgrade')
    $goalDevice = Get-ArthurResumeMember $ProductGoalVerification 'device'
    $goalFactorySha = [string](Get-ArthurResumeMember $ProductGoalVerification 'factory_sha256')
    $legacyFactorySha = [string](Get-ArthurResumeMember $legacyArtifact 'factory_sha256')
    $knownGoodSource = [string](Get-ArthurResumeMember $KnownGood 'source_commit')
    $knownGoodSha = [string](Get-ArthurResumeMember $KnownGood 'sha256')
    if ([string](Get-ArthurResumeMember $Status 'status') -ne 'PRODUCTION_RELEASED' -or
        (Get-ArthurResumeMember $Status 'known_good') -ne $true -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'status') -ne 'PRODUCT_GOAL_VERIFIED' -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'release_status') -ne 'PRODUCTION_RELEASED' -or
        (Get-ArthurResumeMember $KnownGood 'verified') -ne $true -or
        [string](Get-ArthurResumeMember $KnownGood 'status') -ne 'verified' -or
        $sourceSha -notmatch '^[0-9a-fA-F]{40}$' -or
        $firmwareSha -notmatch '^[0-9a-fA-F]{64}$' -or
        $legacyFactorySha -notmatch '^[0-9a-fA-F]{64}$' -or
        [string](Get-ArthurResumeMember $Status 'device') -ne 'jdcloud_re-ss-01' -or
        [string](Get-ArthurResumeMember $KnownGood 'device') -ne 'jdcloud_re-ss-01' -or
        [string](Get-ArthurResumeMember $KnownGood 'target') -ne 'qualcommax' -or
        [string](Get-ArthurResumeMember $KnownGood 'subtarget') -ne 'ipq60xx' -or
        $knownGoodSource -notmatch '^[0-9a-fA-F]{40}$' -or
        $knownGoodSha -notmatch '^[0-9a-fA-F]{64}$' -or
        [string](Get-ArthurResumeMember $goalDevice 'target') -ne 'jdcloud_re-ss-01' -or
        [string](Get-ArthurResumeMember $goalDevice 'model') -ne [string](Get-ArthurResumeMember $legacyDevice 'model') -or
        [string](Get-ArthurResumeMember $goalDevice 'lan_mac') -ne [string](Get-ArthurResumeMember $legacyDevice 'lan_mac') -or
        [string](Get-ArthurResumeMember $Status 'source_commit') -ne $sourceSha -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'source_commit') -ne $sourceSha -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'stable_tag') -ne $stableTag -or
        [string](Get-ArthurResumeMember $Status 'stable_tag') -ne $stableTag -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'sysupgrade_sha256') -ne $firmwareSha -or
        [string](Get-ArthurResumeMember $Status 'sysupgrade_sha256') -ne $firmwareSha -or
        [string](Get-ArthurResumeMember $ProductGoalVerification 'firmware') -ne $firmware -or
        [string](Get-ArthurResumeMember $Status 'firmware') -ne $firmware -or
        $runId -ne [string](Get-ArthurResumeMember $ProductGoalVerification 'build_run_id') -or
        $runId -ne [string](Get-ArthurResumeMember $Status 'run_id') -or
        $artifactId -ne [string](Get-ArthurResumeMember $ProductGoalVerification 'actions_artifact_id') -or
        $artifactId -ne [string](Get-ArthurResumeMember $Status 'artifact_id') -or
        $goalFactorySha -ne $legacyFactorySha -or
        [string](Get-ArthurResumeMember $Status 'factory_sha256') -ne $legacyFactorySha -or
        [string](Get-ArthurResumeMember $legacyDevice 'version') -ne '0.1.5' -or
        [string](Get-ArthurResumeMember $legacyDevice 'build_id') -ne $runId -or
        [string](Get-ArthurResumeMember $Status 'version') -ne 'v0.1.5' -or
        [string](Get-ArthurResumeMember $legacyDevice 'target') -ne 'jdcloud_re-ss-01') {
        throw 'ARTHUR_LEGACY_TERMINAL_STABLE_IDENTITY_CONFLICT'
    }

    $device = $legacyDevice | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $state = [ordered]@{
        schema_version = 2
        execution_id = [string](Get-ArthurResumeMember $Legacy 'execution_id')
        status = 'PRODUCTION_RELEASED'
        instruction_allowed = $false
        release = 'v0.1.5'
        source = [ordered]@{
            repository_head = $RepositoryHead.ToLowerInvariant()
            accepted_source_sha = $sourceSha
            accepted_release = 'v0.1.5'
            accepted_firmware = $firmware
            accepted_firmware_sha256 = $firmwareSha
            accepted_factory_sha256 = [string](Get-ArthurResumeMember $legacyArtifact 'factory_sha256')
        }
        production = [ordered]@{
            github_run_id = [long]$runId
            artifact_id = [long]$artifactId
            release_id = [long](Get-ArthurResumeMember $Status 'release_id')
            release = $stableTag
            release_url = [string](Get-ArthurResumeMember $Status 'release_url')
            firmware = $firmware
            candidate_sha256 = $firmwareSha
            factory_sha256 = [string](Get-ArthurResumeMember $legacyArtifact 'factory_sha256')
        }
        device = $device
        gates = [pscustomobject]@{}
        current_gate = 'PRODUCTION_RELEASED'
        next_action = 'NONE'
        repository_head = $RepositoryHead.ToLowerInvariant()
        real_device = $device
        checkpoint = [ordered]@{ current='PRODUCTION_RELEASED'; next_action='NONE'; turn_count=0 }
        verified = [ordered]@{ real_device_baseline='HISTORICAL_STABLE_IDENTITY_MATCHED'; wifi='VERIFIED_FROZEN'; luci_chinese='REVERIFY_REQUIRED'; adguard_full_manager='REVERIFY_REQUIRED'; quickstart='REVERIFY_REQUIRED' }
        pending = @()
        conflicts = @()
        legacy_gate_summary = Get-ArthurResumeMember $Legacy 'gates'
        migration_basis = 'SCHEMA1_TERMINAL_IDENTITY_MATCHED_TO_STATUS_AND_PRODUCT_GOAL_VERIFICATION'
    }
    $state['semantic_sha256'] = Get-ArthurResumeSemanticHash -State $state
    return [pscustomobject]$state
}

function Resolve-ArthurMigrationExecutionId {
    param(
        [string]$ExplicitExecutionId,
        [object]$PreviousResumeState,
        [object]$BaselineFirmware
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitExecutionId)) {
        $candidate = $ExplicitExecutionId.Trim().ToLowerInvariant()
        if (-not (Test-ArthurExecutionId -ExecutionId $candidate)) {
            throw "ARTHUR_EXECUTION_ID_INVALID=$ExplicitExecutionId"
        }
        return $candidate
    }

    $previous = [string](Get-ArthurResumeMember $PreviousResumeState 'execution_id')
    if (-not [string]::IsNullOrWhiteSpace($previous)) { return $previous }

    $sourceSha = [string](Get-ArthurResumeMember $BaselineFirmware 'source_sha')
    $buildDateText = [string](Get-ArthurResumeMember $BaselineFirmware 'build_date')
    $buildDate = [datetime]'1970-01-01'
    if (-not [string]::IsNullOrWhiteSpace($buildDateText)) {
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParse($buildDateText,[ref]$parsedDate)) { $buildDate = $parsedDate }
    }
    return (New-ArthurExecutionId -TaskSlug 'migrated' -AcceptedSourceSha $sourceSha -Date $buildDate)
}

function Resolve-ArthurGateMap {
    param(
        [object[]]$GateRecords = @(),
        [object]$CurrentSubjects = $null,
        [object]$RequirementDigests = $null
    )

    $map = [ordered]@{}
    foreach ($gate in @($GateRecords)) {
        if ($null -eq $gate) { continue }
        $gateId = [string](Get-ArthurResumeMember $gate 'gate_id')
        if ([string]::IsNullOrWhiteSpace($gateId)) { throw 'ARTHUR_RESUME_GATE_ID_MISSING' }

        $currentSubject = Get-ArthurResumeMapValue $CurrentSubjects $gateId
        if ($null -eq $currentSubject) { $currentSubject = Get-ArthurResumeMember $gate 'subject' }
        $currentDigest = [string](Get-ArthurResumeMapValue $RequirementDigests $gateId)
        if ([string]::IsNullOrWhiteSpace($currentDigest)) { $currentDigest = [string](Get-ArthurResumeMember $gate 'requirement_digest') }

        $status = Resolve-ArthurGateStatus -Gate $gate -CurrentSubject $currentSubject -CurrentRequirementDigest $currentDigest
        $record = New-ArthurGateRecord `
            -GateId $gateId `
            -RequirementRef ([string](Get-ArthurResumeMember $gate 'requirement_ref')) `
            -RequirementDigest ([string](Get-ArthurResumeMember $gate 'requirement_digest')) `
            -Status $status `
            -Subject (Get-ArthurResumeMember $gate 'subject') `
            -EvidenceRefs @((Get-ArthurResumeMember $gate 'evidence_refs')) `
            -Inherited ([bool](Get-ArthurResumeMember $gate 'inherited')) `
            -InheritedFrom ([string](Get-ArthurResumeMember $gate 'inherited_from')) `
            -VerifiedAt ([string](Get-ArthurResumeMember $gate 'verified_at'))
        $map[$gateId] = $record
    }
    return [pscustomobject]$map
}

function Get-ArthurLegacyVerifiedValue {
    param([object]$GateMap,[string]$GateId,[string]$PassValue)
    $gate = Get-ArthurResumeMember $GateMap $GateId
    if ($null -eq $gate -or [string](Get-ArthurResumeMember $gate 'status') -ne 'PASS') { return 'REVERIFY_REQUIRED' }
    return $PassValue
}

function Resolve-ArthurResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryHead,
        [Parameter(Mandatory=$true)][object]$RealDeviceBaseline,
        [object]$LiveDevice = $null,
        [Parameter(Mandatory=$true)][object]$RuntimeState,
        [object]$PreviousResumeState = $null,
        [switch]$AllowBaselineFallbackForMissingLiveDevice,
        [string]$ExecutionId = '',
        [object[]]$GateRecords = @(),
        [object]$CurrentSubjects = $null,
        [object]$RequirementDigests = $null,
        [object]$ProductionIdentity = $null,
        [string]$AcceptedSourceSha = ''
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
    $finalReleasePreFlashFallback = (
        $phase -in @('ARTIFACT','PRE_FLASH') -and
        [string]$env:ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK -eq '1'
    )
    $useBaselineFallback = (
        ($null -eq $LiveDevice) -and
        $activeBaseline -eq $true -and
        ($AllowBaselineFallbackForMissingLiveDevice -or $adhPreviewPhase -or $finalReleaseBuildFallback -or $finalReleasePreFlashFallback)
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

    $resolvedExecutionId = Resolve-ArthurMigrationExecutionId -ExplicitExecutionId $ExecutionId -PreviousResumeState $PreviousResumeState -BaselineFirmware $baselineFirmware
    $gateMap = Resolve-ArthurGateMap -GateRecords $GateRecords -CurrentSubjects $CurrentSubjects -RequirementDigests $RequirementDigests
    $resolvedGateRecords = @(Get-ArthurGateRecordsFromResumeState -ResumeState ([pscustomobject]@{ gates = $gateMap }))
    $gateDriven = $resolvedGateRecords.Count -gt 0
    $nextGate = if ($gateDriven) { Get-ArthurNextRequiredGate -Gates $resolvedGateRecords -GateOrder $script:ArthurResumePhaseOrder } else { $null }
    $resolvedCurrentGate = if ($null -ne $nextGate) { [string](Get-ArthurResumeMember $nextGate 'gate_id') } else { $phase }
    $resolvedNextAction = if ($null -ne $nextGate) { [string](Get-ArthurResumeMember $nextGate 'gate_id') } else { $nextAction }

    $productionRun = Get-ArthurResumeMember $ProductionIdentity 'github_run_id'
    if ($null -eq $productionRun -or [string]::IsNullOrWhiteSpace([string]$productionRun)) { $productionRun = Get-ArthurResumeMember $baselineFirmware 'github_run_id' }
    $productionArtifact = Get-ArthurResumeMember $ProductionIdentity 'artifact_id'
    if ($null -eq $productionArtifact -or [string]::IsNullOrWhiteSpace([string]$productionArtifact)) { $productionArtifact = Get-ArthurResumeMember $baselineFirmware 'artifact_id' }
    $productionCandidateSha = [string](Get-ArthurResumeMember $ProductionIdentity 'candidate_sha256')
    if ([string]::IsNullOrWhiteSpace($productionCandidateSha)) { $productionCandidateSha = [string](Get-ArthurResumeMember $baselineFirmware 'sha256') }

    $safe = ($conflicts.Count -eq 0)
    $acceptedSource = if ($AcceptedSourceSha -match '^[0-9a-fA-F]{40}$') { $AcceptedSourceSha.ToLowerInvariant() } else { $baselineSourceSha }
    $source = [ordered]@{
        repository_head = $RepositoryHead.ToLowerInvariant()
        accepted_source_sha = $acceptedSource
    }
    $production = [ordered]@{
        github_run_id = $(if ($null -eq $productionRun -or [string]::IsNullOrWhiteSpace([string]$productionRun)) { [long]0 } else { [long]$productionRun })
        artifact_id = $(if ($null -eq $productionArtifact -or [string]::IsNullOrWhiteSpace([string]$productionArtifact)) { [long]0 } else { [long]$productionArtifact })
        candidate_sha256 = $productionCandidateSha
    }
    $device = [ordered]@{
        version = $liveVersion
        build_id = $liveBuildId
        git_commit = $liveCommit
        evidence = $liveEvidence
    }

    $state = [ordered]@{
        schema_version = 2
        execution_id = $resolvedExecutionId
        status = $(if ($safe) { 'RESUME_SAFE' } else { 'STATE_RECONCILIATION_REQUIRED' })
        instruction_allowed = $safe
        source = $source
        production = $production
        device = $device
        gates = $gateMap
        current_gate = $resolvedCurrentGate
        next_action = $resolvedNextAction

        # Compatibility fields retained until all existing callers consume schema v2.
        repository_head = $source.repository_head
        real_device = $device
        accepted_baseline = [ordered]@{
            version = $baselineVersion
            build_id = $baselineBuildId
            source_sha = $baselineSourceSha
        }
        checkpoint = [ordered]@{
            current = $resolvedCurrentGate
            next_action = $resolvedNextAction
            turn_count = $turnCount
        }
        verified = [ordered]@{
            real_device_baseline = $(if ($safe) { 'MATCHED' } else { 'RECONCILE_REQUIRED' })
            wifi = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'WIFI' -PassValue 'VERIFIED_FROZEN'
            luci_chinese = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'LUCI_CHINESE' -PassValue 'VERIFIED_FROZEN'
            adguard_full_manager = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'ADGUARD_FULL_MANAGER' -PassValue 'LIVE_BROWSER_VERIFIED'
            quickstart = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'QUICKSTART' -PassValue 'AUTHENTICATED_RENDER_VERIFIED'
        }
        pending = $(if ([string]::IsNullOrWhiteSpace($resolvedNextAction) -or $resolvedNextAction -eq 'NONE') { @() } else { @($resolvedNextAction) })
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
