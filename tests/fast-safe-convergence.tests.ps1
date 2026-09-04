$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Root 'scripts/fast-safe-release-lib.ps1')
. (Join-Path $Root 'scripts/fast-safe-convergence-lib.ps1')

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal($Actual,$Expected,[string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "TEST_FAIL: $Message actual='$Actual' expected='$Expected'" }
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $threw = $false
    try { & $Action } catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "TEST_FAIL: $Message wrong error='$($_.Exception.Message)' expected-pattern='$Pattern'"
        }
    }
    if (-not $threw) { throw "TEST_FAIL: $Message did not throw" }
}

# Durable state must carry convergence evidence without introducing a new production stage.
$state = New-ReleaseTaskState -ReleaseTaskId 'arthur:test:convergence' -DeviceId 'jdcloud_re-ss-01' -CurrentStage 'SOURCE_FROZEN'
Assert-Equal $state.failure_set_state 'COLLECTING' 'new release starts by collecting the complete current failure set'
Assert-Equal $state.failure_set_fingerprint '' 'failure-set fingerprint starts empty'
Assert-Equal $state.verification_contract_fingerprint '' 'verification-contract fingerprint starts empty'
Assert-Equal $state.postflash_mutation_state 'CLEAN' 'post-flash evidence starts clean'
Assert-Equal $state.flash_chain_id '' 'flash chain is not invented before flashing'
Assert-Equal $state.contract_gap_state 'NONE' 'new release has no contract gap'

$failures = @(
    [pscustomobject][ordered]@{
        check_id = 'after_reboot.adguard_page_functional'
        failure_fingerprint = ('a' * 64)
        status = 'OPEN'
    },
    [pscustomobject][ordered]@{
        check_id = 'after_reboot.luci_locale_theme'
        failure_fingerprint = ('b' * 64)
        status = 'OPEN'
    }
)

$frozen = New-FinalFailureSet -Failures $failures -VerificationContractFingerprint ('c' * 64)
Assert-Equal $frozen.state 'FROZEN' 'complete forensic failures are frozen before source repair'
Assert-True ($frozen.failure_set_fingerprint -match '^[0-9a-f]{64}$') 'frozen failure set has a deterministic fingerprint'
Assert-Equal @($frozen.items).Count 2 'all observed failures are retained in the frozen set'

# No rebuild is allowed while any frozen failure is unresolved.
Assert-Throws {
    Assert-RebuildAllowed -FailureSet $frozen -RootfsOfflinePassed $false -FirmwareInputChanged $true
} 'REBUILD_DENIED_FAILURE_SET_UNRESOLVED' 'unresolved failure set must block rebuild'

$cancelPremature = Get-ActiveBuildReconciliationDecision -FailureSetState 'FROZEN' -RunId 33833009848 -RunStatus 'in_progress'
Assert-Equal $cancelPremature.action 'CANCEL_INVALID_BUILD' 'an active build started before convergence must be cancelled'
Assert-Equal $cancelPremature.run_id 33833009848 'cancel decision preserves the exact active run id'

Set-FinalFailureResolution -FailureSet $frozen `
    -CheckId 'after_reboot.adguard_page_functional' `
    -RootCause 'manager menu and ACL generation mismatch' `
    -FirmwareSourceFix 'pin one compatible manager generation in firmware inputs' `
    -PreflashCheckId 'preflash.adguard_manager_generation' `
    -PreflashPassed $true | Out-Null
Assert-Equal $frozen.state 'FROZEN' 'one repaired item cannot prematurely resolve the whole set'

Set-FinalFailureResolution -FailureSet $frozen `
    -CheckId 'after_reboot.luci_locale_theme' `
    -RootCause 'preserved LuCI configuration overrides first-boot locale default' `
    -FirmwareSourceFix 'apply deterministic upgrade-safe zh_cn migration' `
    -PreflashCheckId 'preflash.luci_locale_upgrade_contract' `
    -PreflashPassed $true | Out-Null
Assert-Equal $frozen.state 'RESOLVED' 'failure set resolves only after every item has root cause, source fix, and passing preflash evidence'

Assert-Throws {
    Assert-RebuildAllowed -FailureSet $frozen -RootfsOfflinePassed $false -FirmwareInputChanged $true
} 'REBUILD_DENIED_ROOTFS_OFFLINE_NOT_PASS' 'resolved source fixes still require rootfs offline acceptance'

Assert-Throws {
    Assert-RebuildAllowed -FailureSet $frozen -RootfsOfflinePassed $true -FirmwareInputChanged $false
} 'REBUILD_DENIED_FIRMWARE_INPUT_UNCHANGED' 'a new Candidate requires a real firmware-input fingerprint change'

Assert-True (Assert-RebuildAllowed -FailureSet $frozen -RootfsOfflinePassed $true -FirmwareInputChanged $true) 'one new Candidate is allowed only after convergence and offline acceptance'

$watchResolved = Get-ActiveBuildReconciliationDecision -FailureSetState 'RESOLVED' -RunId 123 -RunStatus 'in_progress'
Assert-Equal $watchResolved.action 'WATCH_EXISTING_RUN' 'a valid active build is watched instead of duplicated'

Assert-Throws {
    Assert-FlashAllowed -FailureSet $frozen -RootfsOfflinePassed $false -CandidateAcceptancePassed $true -ContractGapState 'NONE'
} 'FLASH_DENIED_ROOTFS_OFFLINE_NOT_PASS' 'flash is denied when final rootfs acceptance is missing'
Assert-Throws {
    Assert-FlashAllowed -FailureSet $frozen -RootfsOfflinePassed $true -CandidateAcceptancePassed $false -ContractGapState 'NONE'
} 'FLASH_DENIED_CANDIDATE_ACCEPTANCE_NOT_PASS' 'flash is denied when candidate acceptance is incomplete'
Assert-True (Assert-FlashAllowed -FailureSet $frozen -RootfsOfflinePassed $true -CandidateAcceptancePassed $true -ContractGapState 'NONE') 'flash becomes eligible only after convergence and final candidate acceptance'

# A post-flash hotpatch invalidates release evidence even if the device later looks healthy.
$mutated = Get-PostFlashReleaseDecision -PostFlashMutationState 'MUTATED' -RealDeviceVerifyPassed $true -ContractGapState 'NONE'
Assert-Equal $mutated.action 'DENY_PRODUCTION_RELEASED' 'post-flash mutation can never be promoted'
Assert-Equal $mutated.reason 'POSTFLASH_MUTATED' 'release denial records the exact mutation reason'

$clean = Get-PostFlashReleaseDecision -PostFlashMutationState 'CLEAN' -RealDeviceVerifyPassed $true -ContractGapState 'NONE'
Assert-Equal $clean.action 'ALLOW_PRODUCTION_RELEASED' 'only clean full real-device verification can reach release'

# A previously unseen post-flash failure is a verifier contract gap, not permission to loop rebuild/flash.
$gap = Get-ContractGapDecision -FailureSet $frozen -ObservedFailureFingerprint ('d' * 64) -PreflashTestPresent $false -PreflashTestPassed $false
Assert-Equal $gap.state 'REAL_DEVICE_VERIFY_CONTRACT_GAP' 'new post-flash failure is classified as a contract gap'
Assert-True (-not [bool]$gap.build_allowed) 'contract gap blocks direct rebuild'
Assert-True (-not [bool]$gap.flash_allowed) 'contract gap blocks another flash chain'
Assert-True ([bool]$gap.requires_preflash_contract) 'contract gap requires a new preflash detection contract first'

$known = Get-ContractGapDecision -FailureSet $frozen -ObservedFailureFingerprint ('a' * 64) -PreflashTestPresent $true -PreflashTestPassed $true
Assert-Equal $known.state 'KNOWN_FAILURE' 'a failure already in the frozen set is not mislabeled as a new contract gap'

# The existing real-device verifier is the source of truth for the full current failure set.
$report = [pscustomobject][ordered]@{
    candidate = 'arthur-update-123'
    commit = ('1' * 40)
    result = 'FAIL'
    failures = @(
        [pscustomobject][ordered]@{ name='after_reboot.adguard_page_functional'; command='authenticated GET AdGuard'; output='HTTP 403'; reason='AdGuard manager must render.' },
        [pscustomobject][ordered]@{ name='after_reboot.luci_locale_theme'; command='uci get luci.main.lang'; output='en'; reason='zh_cn and theme resources must be present.' }
    )
}
$evidence = Convert-RealDeviceVerificationToFailureSet -Report $report -VerificationContractFingerprint ('2' * 64) -VerificationReportSha256 ('3' * 64)
Assert-Equal $evidence.state 'FROZEN' 'failed real-device report freezes the complete failure set'
Assert-Equal @($evidence.items).Count 2 'converter consumes every failures[] entry, not only the first Markdown failure'
Assert-Equal $evidence.items[0].check_id 'after_reboot.adguard_page_functional' 'real-device failure name becomes stable check id'
Assert-True ([string]$evidence.items[0].failure_fingerprint -match '^[0-9a-f]{64}$') 'real-device failure gets a stable fingerprint'
Assert-Equal $evidence.verification_report_sha256 ('3' * 64) 'convergence evidence binds to the exact verification report'
Assert-Equal $evidence.rootfs_offline_passed $false 'rootfs acceptance is not invented during forensic collection'

$cleanReport = [pscustomobject][ordered]@{
    candidate = 'known-good-baseline'
    commit = ('4' * 40)
    result = 'PASS'
    failures = @()
}
$cleanEvidence = Convert-RealDeviceVerificationToFailureSet -Report $cleanReport -VerificationContractFingerprint ('5' * 64) -VerificationReportSha256 ('6' * 64)
Assert-Equal $cleanEvidence.state 'RESOLVED' 'a complete clean real-device verification is a resolved zero-failure set'
Assert-Equal @($cleanEvidence.items).Count 0 'clean baseline keeps an explicit zero-failure set'
Assert-True ($cleanEvidence.failure_set_fingerprint -match '^[0-9a-f]{64}$') 'clean zero-failure set still has a deterministic fingerprint'

# Dispatch inputs are emitted only after all failures are resolved and the final rootfs is accepted.
Set-FinalFailureResolution -FailureSet $evidence `
    -CheckId 'after_reboot.adguard_page_functional' `
    -RootCause 'route ACL mismatch' `
    -FirmwareSourceFix 'use one matching menu/ACL generation' `
    -PreflashCheckId 'preflash.adguard.route_acl' `
    -PreflashPassed $true | Out-Null
Set-FinalFailureResolution -FailureSet $evidence `
    -CheckId 'after_reboot.luci_locale_theme' `
    -RootCause 'preserved locale overrides default' `
    -FirmwareSourceFix 'upgrade-safe locale migration' `
    -PreflashCheckId 'preflash.locale.preserved_config' `
    -PreflashPassed $true | Out-Null

Assert-Throws {
    Get-ConvergenceDispatchInputs -Evidence $evidence -CurrentFirmwareInputFingerprint ('7' * 64)
} 'BUILD_DENIED_ROOTFS_OFFLINE_NOT_PASS' 'resolved failures alone cannot dispatch before rootfs acceptance'

Set-ConvergenceRootfsAcceptance -Evidence $evidence -Passed $true -FirmwareInputFingerprint ('7' * 64) | Out-Null
$dispatch = Get-ConvergenceDispatchInputs -Evidence $evidence -CurrentFirmwareInputFingerprint ('7' * 64)
Assert-Equal $dispatch.failure_set_state 'RESOLVED' 'dispatch carries resolved failure-set state'
Assert-Equal $dispatch.rootfs_offline_passed 'true' 'dispatch carries rootfs acceptance evidence'
Assert-Equal $dispatch.contract_gap_state 'NONE' 'dispatch is denied unless contract gap is closed'
Assert-Equal $dispatch.firmware_input_fingerprint ('7' * 64) 'dispatch is bound to the exact accepted firmware input fingerprint'

Assert-Throws {
    Get-ConvergenceDispatchInputs -Evidence $evidence -CurrentFirmwareInputFingerprint ('8' * 64)
} 'BUILD_DENIED_FIRMWARE_INPUT_DRIFT' 'any source change after rootfs acceptance invalidates dispatch permission'

$tempEvidence = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-convergence-$PID-$([Guid]::NewGuid().ToString('N')).json"
try {
    Save-ReleaseConvergenceEvidence -Evidence $evidence -Path $tempEvidence | Out-Null
    $roundTrip = Load-ReleaseConvergenceEvidence -Path $tempEvidence
    Assert-Equal $roundTrip.failure_set_fingerprint $evidence.failure_set_fingerprint 'durable convergence evidence preserves frozen failure identity'
    Assert-Equal $roundTrip.resolved_firmware_input_fingerprint ('7' * 64) 'durable convergence evidence preserves final rootfs/input binding'
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tempEvidence
}

Write-Host 'FAST_SAFE_FINAL_FAILURE_SET_CONTRACT=PASS'
Write-Host 'FAST_SAFE_REBUILD_PERMISSION_CONTRACT=PASS'
Write-Host 'FAST_SAFE_INVALID_BUILD_CANCEL_CONTRACT=PASS'
Write-Host 'FAST_SAFE_FLASH_PERMISSION_CONTRACT=PASS'
Write-Host 'FAST_SAFE_CLEAN_POSTFLASH_CONTRACT=PASS'
Write-Host 'FAST_SAFE_CONTRACT_GAP_CONTRACT=PASS'
Write-Host 'FAST_SAFE_REAL_DEVICE_FAILURE_INGEST_CONTRACT=PASS'
Write-Host 'FAST_SAFE_CONVERGENCE_EVIDENCE_PERSISTENCE_CONTRACT=PASS'
Write-Host 'FAST_SAFE_DISPATCH_EVIDENCE_BINDING_CONTRACT=PASS'
