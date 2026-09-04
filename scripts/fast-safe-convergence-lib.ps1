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
