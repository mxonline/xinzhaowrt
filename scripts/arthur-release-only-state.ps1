Set-StrictMode -Version Latest

$script:ArthurReleaseOnlySkippedGates = @(
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
    'SYSTEM_HEALTH'
)

function Set-ArthurObjectProperty {
    param([Parameter(Mandatory=$true)]$Object,[Parameter(Mandatory=$true)][string]$Name,$Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-ArthurReleaseOnlySkippedGates {
    return @($script:ArthurReleaseOnlySkippedGates)
}

function Complete-ArthurReleaseOnlyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$ResumeState,
        [Parameter(Mandatory=$true)]$OperatorIntent,
        [Parameter(Mandatory=$true)][long]$RunId,
        [Parameter(Mandatory=$true)][long]$ArtifactId,
        [Parameter(Mandatory=$true)][string]$ReleaseTag,
        [Parameter(Mandatory=$true)][string]$SourceSha,
        [Parameter(Mandatory=$true)][string]$Firmware,
        [Parameter(Mandatory=$true)][string]$FirmwareSha256,
        [string]$FactorySha256 = '',
        [Parameter(Mandatory=$true)][long]$ReleaseId,
        [Parameter(Mandatory=$true)][string]$ReleaseUrl,
        [Parameter(Mandatory=$true)][string]$EvidenceId,
        [Parameter(Mandatory=$true)][string]$ReleaseGateEvidenceId,
        [Parameter(Mandatory=$true)][string]$ProductionReleasedEvidenceId
    )

    if ([int]$ResumeState.schema_version -ne 2) { throw 'ARTHUR_RELEASE_ONLY_STATE_SCHEMA_UNSUPPORTED' }
    if ($RunId -le 0 -or $ArtifactId -le 0 -or $ReleaseId -le 0) { throw 'ARTHUR_RELEASE_ONLY_IDENTITY_INVALID' }
    $source = $SourceSha.Trim().ToLowerInvariant()
    $firmwareHash = $FirmwareSha256.Trim().ToLowerInvariant()
    if ($source -notmatch '^[0-9a-f]{40}$') { throw 'ARTHUR_RELEASE_ONLY_SOURCE_SHA_INVALID' }
    if ($firmwareHash -notmatch '^[0-9a-f]{64}$') { throw 'ARTHUR_RELEASE_ONLY_FIRMWARE_SHA_INVALID' }
    if ($FactorySha256 -and $FactorySha256.Trim().ToLowerInvariant() -notmatch '^[0-9a-f]{64}$') { throw 'ARTHUR_RELEASE_ONLY_FACTORY_SHA_INVALID' }
    if ($ReleaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ARTHUR_RELEASE_ONLY_RELEASE_TAG_INVALID' }
    if (-not $EvidenceId -or -not $ReleaseGateEvidenceId -or -not $ProductionReleasedEvidenceId) { throw 'ARTHUR_RELEASE_ONLY_EVIDENCE_ID_MISSING' }

    foreach ($required in @('BUILD','ARTIFACT','RELEASE_GATE','RELEASE','PRODUCTION_RELEASED')) {
        if (-not $ResumeState.gates.PSObject.Properties[$required]) { throw "ARTHUR_RELEASE_ONLY_GATE_MISSING=$required" }
    }
    if ([string]$ResumeState.gates.BUILD.status -ne 'PASS') { throw 'ARTHUR_RELEASE_ONLY_BUILD_NOT_PASS' }
    if ([string]$ResumeState.gates.ARTIFACT.status -ne 'PASS') { throw 'ARTHUR_RELEASE_ONLY_ARTIFACT_NOT_PASS' }

    # Gate timestamps live in the immutable evidence index. Keep the terminal
    # resume projection stable across JSON serialization and timezone parsing.
    $allGates = if ($ResumeState.gates -is [System.Collections.IDictionary]) {
        @($ResumeState.gates.Values)
    } else {
        @($ResumeState.gates.PSObject.Properties | ForEach-Object { $_.Value })
    }
    foreach ($gate in $allGates) {
        if ($null -ne $gate) { Set-ArthurObjectProperty -Object $gate -Name 'verified_at' -Value '' }
    }

    foreach ($gateId in $script:ArthurReleaseOnlySkippedGates) {
        $property = $ResumeState.gates.PSObject.Properties[$gateId]
        if (-not $property) { continue }
        $gate = $property.Value
        $gate.status = 'SKIPPED'
        Set-ArthurObjectProperty -Object $gate -Name 'evidence_refs' -Value @()
        Set-ArthurObjectProperty -Object $gate -Name 'inherited' -Value $false
        Set-ArthurObjectProperty -Object $gate -Name 'inherited_from' -Value ''
        Set-ArthurObjectProperty -Object $gate -Name 'verified_at' -Value ''
    }

    foreach ($gateId in @('RELEASE_GATE','RELEASE','PRODUCTION_RELEASED')) {
        $gate = $ResumeState.gates.PSObject.Properties[$gateId].Value
        $gateEvidenceId = switch ($gateId) {
            'RELEASE_GATE' { $ReleaseGateEvidenceId }
            'RELEASE' { $EvidenceId }
            'PRODUCTION_RELEASED' { $ProductionReleasedEvidenceId }
        }
        $gate.status = 'PASS'
        Set-ArthurObjectProperty -Object $gate -Name 'subject' -Value ([pscustomobject][ordered]@{ source_sha=$source; github_run_id=$RunId; artifact_id=$ArtifactId; candidate_sha256=$firmwareHash; release_tag=$ReleaseTag })
        Set-ArthurObjectProperty -Object $gate -Name 'evidence_refs' -Value @("evidence:$gateEvidenceId")
        Set-ArthurObjectProperty -Object $gate -Name 'inherited' -Value $false
        Set-ArthurObjectProperty -Object $gate -Name 'inherited_from' -Value ''
        Set-ArthurObjectProperty -Object $gate -Name 'verified_at' -Value ''
    }

    Set-ArthurObjectProperty -Object $ResumeState.source -Name 'repository_head' -Value $source
    Set-ArthurObjectProperty -Object $ResumeState.source -Name 'accepted_source_sha' -Value $source
    Set-ArthurObjectProperty -Object $ResumeState.source -Name 'accepted_release' -Value $ReleaseTag
    Set-ArthurObjectProperty -Object $ResumeState.source -Name 'accepted_firmware' -Value $Firmware
    Set-ArthurObjectProperty -Object $ResumeState.source -Name 'accepted_firmware_sha256' -Value $firmwareHash
    if ($FactorySha256) { Set-ArthurObjectProperty -Object $ResumeState.source -Name 'accepted_factory_sha256' -Value $FactorySha256.Trim().ToLowerInvariant() }

    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'github_run_id' -Value $RunId
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'artifact_id' -Value $ArtifactId
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'release_id' -Value $ReleaseId
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'release' -Value $ReleaseTag
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'release_url' -Value $ReleaseUrl
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'firmware' -Value $Firmware
    Set-ArthurObjectProperty -Object $ResumeState.production -Name 'candidate_sha256' -Value $firmwareHash
    if ($FactorySha256) { Set-ArthurObjectProperty -Object $ResumeState.production -Name 'factory_sha256' -Value $FactorySha256.Trim().ToLowerInvariant() }

    $ResumeState.status = 'PRODUCTION_RELEASED'
    $ResumeState.instruction_allowed = $false
    $ResumeState.release = $ReleaseTag
    $ResumeState.current_gate = 'PRODUCTION_RELEASED'
    $ResumeState.next_action = 'NONE'
    Set-ArthurObjectProperty -Object $ResumeState -Name 'pending' -Value @()
    Set-ArthurObjectProperty -Object $ResumeState -Name 'post_release_device_test' -Value 'PENDING_INDEPENDENT'
    if ($ResumeState.PSObject.Properties.Name -contains 'checkpoint' -and $ResumeState.checkpoint) {
        Set-ArthurObjectProperty -Object $ResumeState.checkpoint -Name 'current' -Value 'PRODUCTION_RELEASED'
        Set-ArthurObjectProperty -Object $ResumeState.checkpoint -Name 'next_action' -Value 'NONE'
    }

    Set-ArthurObjectProperty -Object $OperatorIntent -Name 'firmware_execution_authorized' -Value $false
    if ($OperatorIntent.PSObject.Properties.Name -contains 'execution_id') { $OperatorIntent.execution_id = [string]$ResumeState.execution_id }
    if ($OperatorIntent.PSObject.Properties.Name -contains 'firmware_state' -and $OperatorIntent.firmware_state) {
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'current_stage' -Value 'PRODUCTION_RELEASED'
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'next_stage' -Value 'NONE'
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'active_run_id' -Value $RunId
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'active_source_sha' -Value $source
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'active_artifact_id' -Value $ArtifactId
        Set-ArthurObjectProperty -Object $OperatorIntent.firmware_state -Name 'candidate_release_conclusion' -Value 'success'
    }

    return [pscustomobject][ordered]@{
        resume_state = $ResumeState
        operator_intent = $OperatorIntent
        release_tag = $ReleaseTag
        run_id = $RunId
        artifact_id = $ArtifactId
        firmware_sha256 = $firmwareHash
        post_release_device_test = 'PENDING_INDEPENDENT'
    }
}

function Complete-ArthurReleaseOnlyStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Status,
        [Parameter(Mandatory=$true)][long]$RunId,
        [Parameter(Mandatory=$true)][long]$ArtifactId,
        [Parameter(Mandatory=$true)][string]$CandidateTag,
        [Parameter(Mandatory=$true)][long]$CandidateReleaseId,
        [Parameter(Mandatory=$true)][string]$CandidateReleaseUrl,
        [Parameter(Mandatory=$true)][string]$ActionsArtifactSha256,
        [Parameter(Mandatory=$true)][string]$ReleaseTag,
        [Parameter(Mandatory=$true)][string]$SourceSha,
        [Parameter(Mandatory=$true)][string]$Firmware,
        [Parameter(Mandatory=$true)][string]$FirmwareSha256,
        [string]$FactoryFirmware = '',
        [string]$FactorySha256 = '',
        [Parameter(Mandatory=$true)][long]$ReleaseId,
        [Parameter(Mandatory=$true)][string]$ReleaseUrl,
        [string]$BuildRunUrl = '',
        [string]$VerifiedAt = ''
    )

    if ($RunId -le 0 -or $ArtifactId -le 0 -or $CandidateReleaseId -le 0 -or $ReleaseId -le 0) {
        throw 'ARTHUR_RELEASE_ONLY_STATUS_IDENTITY_INVALID'
    }
    if ($CandidateTag -ne "arthur-update-$RunId") { throw 'ARTHUR_RELEASE_ONLY_STATUS_CANDIDATE_TAG_MISMATCH' }
    if ($ReleaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ARTHUR_RELEASE_ONLY_STATUS_RELEASE_TAG_INVALID' }
    $source = $SourceSha.Trim().ToLowerInvariant()
    $artifactArchiveHash = $ActionsArtifactSha256.Trim().ToLowerInvariant()
    $sysupgradeHash = $FirmwareSha256.Trim().ToLowerInvariant()
    $factoryHash = $FactorySha256.Trim().ToLowerInvariant()
    if ($source -notmatch '^[0-9a-f]{40}$') { throw 'ARTHUR_RELEASE_ONLY_STATUS_SOURCE_SHA_INVALID' }
    if ($artifactArchiveHash -notmatch '^[0-9a-f]{64}$') { throw 'ARTHUR_RELEASE_ONLY_STATUS_ARTIFACT_SHA_INVALID' }
    if ($sysupgradeHash -notmatch '^[0-9a-f]{64}$') { throw 'ARTHUR_RELEASE_ONLY_STATUS_SYSUPGRADE_SHA_INVALID' }
    if ($factoryHash -and $factoryHash -notmatch '^[0-9a-f]{64}$') { throw 'ARTHUR_RELEASE_ONLY_STATUS_FACTORY_SHA_INVALID' }
    if (-not $VerifiedAt) { $VerifiedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    if (-not $BuildRunUrl) { $BuildRunUrl = "https://github.com/mxonline/xinzhaowrt/actions/runs/$RunId" }

    $updates = [ordered]@{
        status = 'PRODUCTION_RELEASED'
        stage = 'production'
        conclusion = 'success'
        device = 'jdcloud_re-ss-01'
        version = $ReleaseTag
        run_id = $RunId
        build_run_id = [string]$RunId
        build_run_url = $BuildRunUrl
        artifact_id = [string]$ArtifactId
        candidate_tag = $CandidateTag
        candidate_release_id = $CandidateReleaseId
        candidate_release_url = $CandidateReleaseUrl
        actions_artifact_sha256 = $artifactArchiveHash
        stable_tag = $ReleaseTag
        release_id = $ReleaseId
        release_url = $ReleaseUrl
        firmware = $Firmware
        sha256 = $sysupgradeHash
        sysupgrade_sha256 = $sysupgradeHash
        project_commit = $source
        source_commit = $source
        source_binding = 'PASS'
        identical_artifact_promotion = 'PASS'
        production_released = 'PASS'
        known_good = $false
        device_exact_artifact_match = 'PENDING_INDEPENDENT'
        post_release_device_test = 'PENDING_INDEPENDENT'
        product_goal_status = 'POST_RELEASE_VALIDATION_PENDING'
        NEXT_ACTION = 'NONE'
        message = "Arthur $ReleaseTag Stable Release published from exact Candidate run $RunId. Post-release device validation is pending; Known-Good remains unchanged."
        updated_at = $VerifiedAt
    }
    foreach ($name in $updates.Keys) {
        Set-ArthurObjectProperty -Object $Status -Name $name -Value $updates[$name]
    }

    if ($FactoryFirmware) {
        Set-ArthurObjectProperty -Object $Status -Name 'factory_firmware' -Value $FactoryFirmware
        Set-ArthurObjectProperty -Object $Status -Name 'factory_sha256' -Value $factoryHash
    }

    foreach ($name in @(
        'live_apk_update',
        'live_luci_package_manager',
        'live_quickstart_software_source_status',
        'live_reboot_persistence',
        'postflash_apk_update',
        'postflash_luci_package_manager',
        'postflash_quickstart_source_status',
        'reboot_persistence'
    )) {
        if ($Status.PSObject.Properties.Name -contains $name) {
            Set-ArthurObjectProperty -Object $Status -Name $name -Value 'PENDING_INDEPENDENT'
        }
    }

    $evidenceRefs = @()
    if ($Status.PSObject.Properties.Name -contains 'evidence' -and $null -ne $Status.evidence) {
        $evidenceRefs = @($Status.evidence | ForEach-Object { [string]$_ })
    }
    foreach ($reference in @($BuildRunUrl,$CandidateReleaseUrl,$ReleaseUrl)) {
        if ($reference -and $evidenceRefs -notcontains $reference) { $evidenceRefs += $reference }
    }
    Set-ArthurObjectProperty -Object $Status -Name 'evidence' -Value $evidenceRefs

    return $Status
}
