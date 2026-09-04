$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Root 'scripts/fast-safe-release-lib.ps1')
. (Join-Path $Root 'scripts/fast-safe-convergence-lib.ps1')
. (Join-Path $Root 'scripts/release-convergence-exec-lib.ps1')
. (Join-Path $Root 'scripts/production-agent-convergence-lib.ps1')

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "TEST_FAIL: $Message" } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $threw=$false
    try { & $Action } catch {
        $threw=$true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "TEST_FAIL: $Message wrong='$($_.Exception.Message)' expected='$Pattern'" }
    }
    if (-not $threw) { throw "TEST_FAIL: $Message did not throw" }
}

$tmp=Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhao-production-convergence-$PID-$([Guid]::NewGuid().ToString('N'))")
$oldLocal=$env:LOCALAPPDATA
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:LOCALAPPDATA=$tmp
try {
    $fingerprint=('c' * 64)
    $failureSet=New-FinalFailureSet -Failures @(
        [pscustomobject][ordered]@{check_id='after_reboot.test';failure_fingerprint=('a' * 64);status='OPEN'}
    ) -VerificationContractFingerprint ('b' * 64)
    Set-FinalFailureResolution -FailureSet $failureSet -CheckId 'after_reboot.test' -RootCause 'proven' -FirmwareSourceFix 'fixed' -PreflashCheckId 'preflash.test' -PreflashPassed $true | Out-Null
    Add-ConvergenceEvidenceMetadata -Evidence $failureSet -Report ([pscustomobject]@{result='FAIL';candidate='old';commit=('1'*40)}) -VerificationReportSha256 ('d'*64) | Out-Null
    Set-ConvergenceRootfsAcceptance -Evidence $failureSet -Passed $true -FirmwareInputFingerprint $fingerprint | Out-Null
    Save-ReleaseConvergenceEvidence -Evidence $failureSet -Path (Get-ProductionConvergenceEvidencePath) | Out-Null

    function Get-ProductionFirmwareInputFingerprint { param($State) return ('c' * 64) }

    $state=[pscustomobject]@{
        run_id=[long]77
        source_sha=('1' * 40)
        candidate_sha256=('e' * 64)
        flash_chain_id=''
        postflash_mutation_state='CLEAN'
        contract_gap_state='NONE'
    }

    Assert-True ([bool](Assert-ProductionConvergenceBeforeFlash -State $state)) 'resolved/rootfs-bound evidence must allow preflash gate'

    $blocked=Load-ProductionConvergenceEvidence
    $blocked.rootfs_offline_passed=$false
    Save-ReleaseConvergenceEvidence -Evidence $blocked -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Assert-Throws { Assert-ProductionConvergenceBeforeFlash -State $state | Out-Null } 'ROOTFS|rootfs' 'missing rootfs acceptance must block flash'

    $blocked.rootfs_offline_passed=$true
    Save-ReleaseConvergenceEvidence -Evidence $blocked -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Start-ProductionFlashChain -State $state | Out-Null
    Assert-True ([string]$state.flash_chain_id -match '^[0-9a-f]{64}$') 'first permitted flash creates one deterministic chain id'
    Assert-Throws { Start-ProductionFlashChain -State $state | Out-Null } 'FLASH_CHAIN_ALREADY_STARTED' 'same production state cannot start a second flash chain'

    $clean=Load-ProductionConvergenceEvidence
    Add-ConvergenceNoteProperty -Object $clean -Name 'postflash_verification_result' -Value 'PASS'
    $clean.postflash_mutation_state='CLEAN'
    $clean.contract_gap_state='NONE'
    Save-ReleaseConvergenceEvidence -Evidence $clean -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Assert-True (Assert-ProductionReleaseConvergence -State $state) 'clean PASS from same flash chain may release'

    $mutated=Load-ProductionConvergenceEvidence
    $mutated.postflash_mutation_state='MUTATED'
    Save-ReleaseConvergenceEvidence -Evidence $mutated -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Assert-Throws { Assert-ProductionReleaseConvergence -State $state | Out-Null } 'DENY_PRODUCTION_RELEASED.*POSTFLASH_MUTATED' 'postflash mutation must deny release'

    $gap=Load-ProductionConvergenceEvidence
    $gap.postflash_mutation_state='CLEAN'
    $gap.contract_gap_state='REAL_DEVICE_VERIFY_CONTRACT_GAP'
    Save-ReleaseConvergenceEvidence -Evidence $gap -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Assert-Throws { Assert-ProductionReleaseConvergence -State $state | Out-Null } 'DENY_PRODUCTION_RELEASED.*CONTRACT_GAP' 'new verifier contract gap must deny release'
} finally {
    $env:LOCALAPPDATA=$oldLocal
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

Write-Host 'PRODUCTION_AGENT_BEHAVIOR_PREFLASH_DENY=PASS'
Write-Host 'PRODUCTION_AGENT_BEHAVIOR_SINGLE_FLASH=PASS'
Write-Host 'PRODUCTION_AGENT_BEHAVIOR_MUTATION_DENY=PASS'
Write-Host 'PRODUCTION_AGENT_BEHAVIOR_CONTRACT_GAP_DENY=PASS'
Write-Host 'PRODUCTION_AGENT_BEHAVIOR_CLEAN_RELEASE=PASS'
