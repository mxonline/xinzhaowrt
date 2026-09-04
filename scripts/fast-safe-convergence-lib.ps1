Set-StrictMode -Version Latest

if (Get-Variable -Name FastSafeConvergenceLoaded -Scope Script -ErrorAction SilentlyContinue) {
    return
}
$script:FastSafeConvergenceLoaded = $true

function Add-ConvergenceStateDefaults {
    param([Parameter(Mandatory)]$State)
    Add-ReleaseStateDefault $State 'failure_set_state' 'COLLECTING'
    Add-ReleaseStateDefault $State 'failure_set_fingerprint' ''
    Add-ReleaseStateDefault $State 'verification_contract_fingerprint' ''
    Add-ReleaseStateDefault $State 'postflash_mutation_state' 'CLEAN'
    Add-ReleaseStateDefault $State 'flash_chain_id' ''
    Add-ReleaseStateDefault $State 'contract_gap_state' 'NONE'
    Add-ReleaseStateDefault $State 'failure_items' @()
    return $State
}

$script:FastSafeBaseNewReleaseTaskState = ${function:New-ReleaseTaskState}
function New-ReleaseTaskState {
    param(
        [Parameter(Mandatory)][string]$ReleaseTaskId,
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$CurrentStage
    )
    $state = & $script:FastSafeBaseNewReleaseTaskState `
        -ReleaseTaskId $ReleaseTaskId `
        -DeviceId $DeviceId `
        -CurrentStage $CurrentStage
    return (Add-ConvergenceStateDefaults -State $state)
}

$script:FastSafeBaseConvertToReleaseTaskStateV2 = ${function:ConvertTo-ReleaseTaskStateV2}
function ConvertTo-ReleaseTaskStateV2 {
    param(
        [Parameter(Mandatory)]$State,
        [string]$DeviceId = 'jdcloud_re-ss-01'
    )
    $copy = & $script:FastSafeBaseConvertToReleaseTaskStateV2 -State $State -DeviceId $DeviceId
    return (Add-ConvergenceStateDefaults -State $copy)
}

function New-FinalFailureSet {
    param(
        [Parameter(Mandatory)][object[]]$Failures,
        [Parameter(Mandatory)][string]$VerificationContractFingerprint
    )
    if ($VerificationContractFingerprint -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'FINAL_FAILURE_SET_VERIFICATION_CONTRACT_FINGERPRINT_INVALID'
    }
    if (@($Failures).Count -eq 0) {
        throw 'FINAL_FAILURE_SET_EMPTY'
    }

    $items = New-Object System.Collections.Generic.List[object]
    $identity = New-Object System.Collections.Generic.List[string]
    foreach ($failure in @($Failures | Sort-Object { [string]$_.check_id })) {
        if ($failure.PSObject.Properties.Name -notcontains 'check_id' -or -not [string]$failure.check_id) {
            throw 'FINAL_FAILURE_SET_CHECK_ID_MISSING'
        }
        if ($failure.PSObject.Properties.Name -notcontains 'failure_fingerprint' -or [string]$failure.failure_fingerprint -notmatch '^[0-9a-fA-F]{64}$') {
            throw "FINAL_FAILURE_SET_FAILURE_FINGERPRINT_INVALID=$([string]$failure.check_id)"
        }
        $status = if ($failure.PSObject.Properties.Name -contains 'status' -and [string]$failure.status) { [string]$failure.status } else { 'OPEN' }
        $item = [pscustomobject][ordered]@{
            check_id = [string]$failure.check_id
            failure_fingerprint = ([string]$failure.failure_fingerprint).ToLowerInvariant()
            status = $status
            root_cause = ''
            firmware_source_fix = ''
            preflash_check_id = ''
            preflash_passed = $false
        }
        $items.Add($item)
        $identity.Add("$($item.check_id)|$($item.failure_fingerprint)")
    }

    $verification = $VerificationContractFingerprint.ToLowerInvariant()
    $failureSetFingerprint = Get-Sha256HexFromText -Text ((@("verification=$verification") + @($identity.ToArray())) -join "`n")
    return [pscustomobject][ordered]@{
        state = 'FROZEN'
        verification_contract_fingerprint = $verification
        failure_set_fingerprint = $failureSetFingerprint
        items = @($items.ToArray())
        frozen_at = (Get-Date).ToUniversalTime().ToString('o')
        resolved_at = ''
    }
}

function Set-FinalFailureResolution {
    param(
        [Parameter(Mandatory)]$FailureSet,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$RootCause,
        [Parameter(Mandatory)][string]$FirmwareSourceFix,
        [Parameter(Mandatory)][string]$PreflashCheckId,
        [Parameter(Mandatory)][bool]$PreflashPassed
    )
    if ([string]$FailureSet.state -notin @('FROZEN','RESOLVED')) {
        throw "FINAL_FAILURE_SET_STATE_INVALID=$([string]$FailureSet.state)"
    }
    if (-not $RootCause.Trim()) { throw 'FINAL_FAILURE_ROOT_CAUSE_REQUIRED' }
    if (-not $FirmwareSourceFix.Trim()) { throw 'FINAL_FAILURE_SOURCE_FIX_REQUIRED' }
    if (-not $PreflashCheckId.Trim()) { throw 'FINAL_FAILURE_PREFLASH_CHECK_REQUIRED' }

    $item = @($FailureSet.items | Where-Object { [string]$_.check_id -eq $CheckId }) | Select-Object -First 1
    if (-not $item) { throw "FINAL_FAILURE_CHECK_NOT_FOUND=$CheckId" }

    $item.root_cause = $RootCause.Trim()
    $item.firmware_source_fix = $FirmwareSourceFix.Trim()
    $item.preflash_check_id = $PreflashCheckId.Trim()
    $item.preflash_passed = $PreflashPassed
    $item.status = if ($PreflashPassed) { 'RESOLVED' } else { 'OPEN' }

    $allResolved = $true
    foreach ($candidate in @($FailureSet.items)) {
        if ([string]$candidate.status -ne 'RESOLVED' -or
            -not [string]$candidate.root_cause -or
            -not [string]$candidate.firmware_source_fix -or
            -not [string]$candidate.preflash_check_id -or
            $candidate.preflash_passed -ne $true) {
            $allResolved = $false
            break
        }
    }
    if ($allResolved) {
        $FailureSet.state = 'RESOLVED'
        $FailureSet.resolved_at = (Get-Date).ToUniversalTime().ToString('o')
    } else {
        $FailureSet.state = 'FROZEN'
        $FailureSet.resolved_at = ''
    }
    return $item
}

function Assert-RebuildAllowed {
    param(
        [Parameter(Mandatory)]$FailureSet,
        [Parameter(Mandatory)][bool]$RootfsOfflinePassed,
        [Parameter(Mandatory)][bool]$FirmwareInputChanged
    )
    if ([string]$FailureSet.state -ne 'RESOLVED') {
        throw 'REBUILD_DENIED_FAILURE_SET_UNRESOLVED'
    }
    if (-not $RootfsOfflinePassed) {
        throw 'REBUILD_DENIED_ROOTFS_OFFLINE_NOT_PASS'
    }
    if (-not $FirmwareInputChanged) {
        throw 'REBUILD_DENIED_FIRMWARE_INPUT_UNCHANGED'
    }
    return $true
}

function Get-ActiveBuildReconciliationDecision {
    param(
        [Parameter(Mandatory)][ValidateSet('COLLECTING','FROZEN','RESOLVED')][string]$FailureSetState,
        [Parameter(Mandatory)][long]$RunId,
        [Parameter(Mandatory)][string]$RunStatus
    )
    if ($RunId -le 0) { throw 'ACTIVE_BUILD_RUN_ID_INVALID' }
    $activeStatuses = @('queued','in_progress','waiting','requested','pending')
    if ($RunStatus -notin $activeStatuses) {
        return [pscustomobject][ordered]@{ action='NO_ACTIVE_BUILD'; run_id=$RunId; reason='RUN_NOT_ACTIVE' }
    }
    if ($FailureSetState -ne 'RESOLVED') {
        return [pscustomobject][ordered]@{ action='CANCEL_INVALID_BUILD'; run_id=$RunId; reason='FINAL_FAILURE_SET_NOT_RESOLVED' }
    }
    return [pscustomobject][ordered]@{ action='WATCH_EXISTING_RUN'; run_id=$RunId; reason='ACTIVE_BUILD_VALID' }
}

function Assert-FlashAllowed {
    param(
        [Parameter(Mandatory)]$FailureSet,
        [Parameter(Mandatory)][bool]$RootfsOfflinePassed,
        [Parameter(Mandatory)][bool]$CandidateAcceptancePassed,
        [Parameter(Mandatory)][string]$ContractGapState
    )
    if ([string]$FailureSet.state -ne 'RESOLVED') {
        throw 'FLASH_DENIED_FAILURE_SET_UNRESOLVED'
    }
    if (-not $RootfsOfflinePassed) {
        throw 'FLASH_DENIED_ROOTFS_OFFLINE_NOT_PASS'
    }
    if (-not $CandidateAcceptancePassed) {
        throw 'FLASH_DENIED_CANDIDATE_ACCEPTANCE_NOT_PASS'
    }
    if ($ContractGapState -ne 'NONE') {
        throw 'FLASH_DENIED_CONTRACT_GAP'
    }
    return $true
}

function Get-PostFlashReleaseDecision {
    param(
        [Parameter(Mandatory)][ValidateSet('CLEAN','MUTATED')][string]$PostFlashMutationState,
        [Parameter(Mandatory)][bool]$RealDeviceVerifyPassed,
        [Parameter(Mandatory)][string]$ContractGapState
    )
    if ($PostFlashMutationState -eq 'MUTATED') {
        return [pscustomobject][ordered]@{ action='DENY_PRODUCTION_RELEASED'; reason='POSTFLASH_MUTATED' }
    }
    if ($ContractGapState -ne 'NONE') {
        return [pscustomobject][ordered]@{ action='DENY_PRODUCTION_RELEASED'; reason='REAL_DEVICE_VERIFY_CONTRACT_GAP' }
    }
    if (-not $RealDeviceVerifyPassed) {
        return [pscustomobject][ordered]@{ action='DENY_PRODUCTION_RELEASED'; reason='REAL_DEVICE_VERIFY_NOT_PASS' }
    }
    return [pscustomobject][ordered]@{ action='ALLOW_PRODUCTION_RELEASED'; reason='CLEAN_REAL_DEVICE_VERIFY_PASS' }
}

function Get-ContractGapDecision {
    param(
        [Parameter(Mandatory)]$FailureSet,
        [Parameter(Mandatory)][string]$ObservedFailureFingerprint,
        [Parameter(Mandatory)][bool]$PreflashTestPresent,
        [Parameter(Mandatory)][bool]$PreflashTestPassed
    )
    if ($ObservedFailureFingerprint -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'CONTRACT_GAP_FAILURE_FINGERPRINT_INVALID'
    }
    $fingerprint = $ObservedFailureFingerprint.ToLowerInvariant()
    $known = @($FailureSet.items | Where-Object { [string]$_.failure_fingerprint -eq $fingerprint }) | Select-Object -First 1
    if ($known) {
        return [pscustomobject][ordered]@{
            state = 'KNOWN_FAILURE'
            build_allowed = $false
            flash_allowed = $false
            requires_preflash_contract = (-not $PreflashTestPresent -or -not $PreflashTestPassed)
            failure_fingerprint = $fingerprint
        }
    }

    $contractClosed = $PreflashTestPresent -and $PreflashTestPassed
    return [pscustomobject][ordered]@{
        state = if ($contractClosed) { 'CONTRACT_GAP_CLOSED' } else { 'REAL_DEVICE_VERIFY_CONTRACT_GAP' }
        build_allowed = $false
        flash_allowed = $false
        requires_preflash_contract = (-not $contractClosed)
        failure_fingerprint = $fingerprint
    }
}

function Get-RealDeviceFailureFingerprint {
    param([Parameter(Mandatory)]$Failure)
    foreach ($name in @('name','command','reason')) {
        if ($Failure.PSObject.Properties.Name -notcontains $name) {
            throw "REAL_DEVICE_FAILURE_FIELD_MISSING=$name"
        }
    }
    $checkId = [string]$Failure.name
    if (-not $checkId.Trim()) { throw 'REAL_DEVICE_FAILURE_NAME_EMPTY' }
    $canonical = @(
        "check_id=$($checkId.Trim())",
        "command=$(([string]$Failure.command).Trim())",
        "reason=$(([string]$Failure.reason).Trim())"
    ) -join "`n"
    return Get-Sha256HexFromText -Text $canonical
}

function Add-ConvergenceEvidenceMetadata {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$VerificationReportSha256
    )
    Add-ReleaseStateDefault $Evidence 'schema_version' 1
    Add-ReleaseStateDefault $Evidence 'verification_report_sha256' $VerificationReportSha256.ToLowerInvariant()
    Add-ReleaseStateDefault $Evidence 'verification_result' ([string]$Report.result).ToUpperInvariant()
    Add-ReleaseStateDefault $Evidence 'candidate' ([string]$Report.candidate)
    Add-ReleaseStateDefault $Evidence 'commit' ([string]$Report.commit)
    Add-ReleaseStateDefault $Evidence 'rootfs_offline_passed' $false
    Add-ReleaseStateDefault $Evidence 'resolved_firmware_input_fingerprint' ''
    Add-ReleaseStateDefault $Evidence 'contract_gap_state' 'NONE'
    Add-ReleaseStateDefault $Evidence 'postflash_mutation_state' 'CLEAN'
    Add-ReleaseStateDefault $Evidence 'updated_at' (Get-Date).ToUniversalTime().ToString('o')
    return $Evidence
}

function Convert-RealDeviceVerificationToFailureSet {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$VerificationContractFingerprint,
        [Parameter(Mandatory)][string]$VerificationReportSha256
    )
    if ($VerificationContractFingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'FINAL_FAILURE_SET_VERIFICATION_CONTRACT_FINGERPRINT_INVALID' }
    if ($VerificationReportSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'REAL_DEVICE_VERIFICATION_REPORT_SHA256_INVALID' }
    foreach ($name in @('candidate','commit','result','failures')) {
        if ($Report.PSObject.Properties.Name -notcontains $name) { throw "REAL_DEVICE_VERIFICATION_FIELD_MISSING=$name" }
    }
    $result = ([string]$Report.result).ToUpperInvariant()
    if ($result -notin @('PASS','FAIL')) { throw "REAL_DEVICE_VERIFICATION_RESULT_INVALID=$result" }
    $rawFailures = @($Report.failures)
    if ($rawFailures.Count -eq 0) {
        if ($result -ne 'PASS') { throw 'REAL_DEVICE_VERIFICATION_FAIL_WITHOUT_FAILURES' }
        $verification = $VerificationContractFingerprint.ToLowerInvariant()
        $cleanFingerprint = Get-Sha256HexFromText -Text "verification=$verification`nclean=PASS"
        $clean = [pscustomobject][ordered]@{
            state = 'RESOLVED'
            verification_contract_fingerprint = $verification
            failure_set_fingerprint = $cleanFingerprint
            items = @()
            frozen_at = (Get-Date).ToUniversalTime().ToString('o')
            resolved_at = (Get-Date).ToUniversalTime().ToString('o')
        }
        return Add-ConvergenceEvidenceMetadata -Evidence $clean -Report $Report -VerificationReportSha256 $VerificationReportSha256
    }

    $prepared = New-Object System.Collections.Generic.List[object]
    foreach ($failure in $rawFailures) {
        $prepared.Add([pscustomobject][ordered]@{
            check_id = ([string]$failure.name).Trim()
            failure_fingerprint = Get-RealDeviceFailureFingerprint -Failure $failure
            status = 'OPEN'
        })
    }
    $evidence = New-FinalFailureSet -Failures @($prepared.ToArray()) -VerificationContractFingerprint $VerificationContractFingerprint
    return Add-ConvergenceEvidenceMetadata -Evidence $evidence -Report $Report -VerificationReportSha256 $VerificationReportSha256
}

function Set-ConvergenceRootfsAcceptance {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$FirmwareInputFingerprint
    )
    if ([string]$Evidence.state -ne 'RESOLVED') { throw 'BUILD_DENIED_FAILURE_SET_UNRESOLVED' }
    if ($FirmwareInputFingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'FIRMWARE_INPUT_FINGERPRINT_INVALID' }
    Add-ReleaseStateDefault $Evidence 'rootfs_offline_passed' $false
    Add-ReleaseStateDefault $Evidence 'resolved_firmware_input_fingerprint' ''
    $Evidence.rootfs_offline_passed = $Passed
    $Evidence.resolved_firmware_input_fingerprint = if ($Passed) { $FirmwareInputFingerprint.ToLowerInvariant() } else { '' }
    $Evidence.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    return $Evidence
}

function Get-ConvergenceDispatchInputs {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$CurrentFirmwareInputFingerprint
    )
    if ($CurrentFirmwareInputFingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'FIRMWARE_INPUT_FINGERPRINT_INVALID' }
    if ([string]$Evidence.state -ne 'RESOLVED') { throw 'BUILD_DENIED_FAILURE_SET_UNRESOLVED' }
    if ($Evidence.PSObject.Properties.Name -notcontains 'rootfs_offline_passed' -or $Evidence.rootfs_offline_passed -ne $true) {
        throw 'BUILD_DENIED_ROOTFS_OFFLINE_NOT_PASS'
    }
    if ($Evidence.PSObject.Properties.Name -notcontains 'contract_gap_state' -or [string]$Evidence.contract_gap_state -ne 'NONE') {
        throw "BUILD_DENIED_CONTRACT_GAP=$([string]$Evidence.contract_gap_state)"
    }
    if ($Evidence.PSObject.Properties.Name -notcontains 'resolved_firmware_input_fingerprint') { throw 'BUILD_DENIED_FIRMWARE_INPUT_BINDING_MISSING' }
    $expected = ([string]$Evidence.resolved_firmware_input_fingerprint).ToLowerInvariant()
    $actual = $CurrentFirmwareInputFingerprint.ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'BUILD_DENIED_FIRMWARE_INPUT_BINDING_MISSING' }
    if ($expected -ne $actual) { throw "BUILD_DENIED_FIRMWARE_INPUT_DRIFT expected=$expected actual=$actual" }
    return [pscustomobject][ordered]@{
        failure_set_state = [string]$Evidence.state
        failure_set_fingerprint = ([string]$Evidence.failure_set_fingerprint).ToLowerInvariant()
        verification_contract_fingerprint = ([string]$Evidence.verification_contract_fingerprint).ToLowerInvariant()
        rootfs_offline_passed = 'true'
        contract_gap_state = [string]$Evidence.contract_gap_state
        firmware_input_fingerprint = $actual
    }
}

function Save-ReleaseConvergenceEvidence {
    param([Parameter(Mandatory)]$Evidence,[Parameter(Mandatory)][string]$Path)
    if ([string]$Evidence.failure_set_fingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'CONVERGENCE_EVIDENCE_FAILURE_SET_FINGERPRINT_INVALID' }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-ReleaseStateDefault $Evidence 'updated_at' (Get-Date).ToUniversalTime().ToString('o')
    $Evidence.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $tmp = "$Path.tmp"
    $Evidence | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $Path
    return $Evidence
}

function Load-ReleaseConvergenceEvidence {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $evidence = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 40 }
    catch { throw "CONVERGENCE_EVIDENCE_INVALID: $($_.Exception.Message)" }
    foreach ($name in @('state','failure_set_fingerprint','verification_contract_fingerprint','items','rootfs_offline_passed','resolved_firmware_input_fingerprint','contract_gap_state')) {
        if ($evidence.PSObject.Properties.Name -notcontains $name) { throw "CONVERGENCE_EVIDENCE_FIELD_MISSING=$name" }
    }
    if ([string]$evidence.failure_set_fingerprint -notmatch '^[0-9a-f]{64}$') { throw 'CONVERGENCE_EVIDENCE_FAILURE_SET_FINGERPRINT_INVALID' }
    return $evidence
}
