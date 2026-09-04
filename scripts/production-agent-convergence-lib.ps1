Set-StrictMode -Version Latest

if (Get-Variable -Name ProductionAgentConvergenceLoaded -Scope Script -ErrorAction SilentlyContinue) {
    return
}
$script:ProductionAgentConvergenceLoaded = $true

function Get-ProductionConvergenceEvidencePath {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff\release-convergence.json')
    }
    return (Join-Path $Root 'output\release-convergence\release-convergence.json')
}

function Get-ProductionRealDeviceReportPath {
    return (Join-Path $Root 'output\real-device\real-device-verification.json')
}

function Get-ProductionFirmwareInputFingerprint {
    param([Parameter(Mandatory)]$State)
    $sourceSha = [string]$State.source_sha
    if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw "PRODUCTION_CONVERGENCE_SOURCE_SHA_INVALID=$sourceSha" }
    $scriptPath = Join-Path $Root 'scripts\get-firmware-input-fingerprint.sh'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'PRODUCTION_CONVERGENCE_FINGERPRINT_SCRIPT_MISSING' }
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { throw 'PRODUCTION_CONVERGENCE_BASH_UNAVAILABLE' }
    $raw = @(& $bash.Source $scriptPath $sourceSha 2>&1)
    $code = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0) { throw "PRODUCTION_CONVERGENCE_FINGERPRINT_FAILED exit=$code output=$text" }
    $fingerprint = $text.Trim()
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw "PRODUCTION_CONVERGENCE_FINGERPRINT_INVALID=$fingerprint" }
    return $fingerprint
}

function Load-ProductionConvergenceEvidence {
    $path = Get-ProductionConvergenceEvidencePath
    $evidence = Load-ReleaseConvergenceEvidence -Path $path
    if (-not $evidence) { throw "PRODUCTION_CONVERGENCE_EVIDENCE_MISSING=$path" }
    return $evidence
}

function Sync-ProductionConvergenceState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Evidence)
    foreach ($pair in @{
        postflash_mutation_state = [string]$Evidence.postflash_mutation_state
        contract_gap_state = [string]$Evidence.contract_gap_state
    }.GetEnumerator()) {
        if ($State.PSObject.Properties.Name -contains $pair.Key) { $State.($pair.Key) = $pair.Value }
        else { Add-Member -InputObject $State -NotePropertyName $pair.Key -NotePropertyValue $pair.Value }
    }
    if ($Evidence.PSObject.Properties.Name -contains 'flash_chain_id' -and [string]$Evidence.flash_chain_id) {
        if ($State.PSObject.Properties.Name -contains 'flash_chain_id') { $State.flash_chain_id = [string]$Evidence.flash_chain_id }
        else { Add-Member -InputObject $State -NotePropertyName flash_chain_id -NotePropertyValue ([string]$Evidence.flash_chain_id) }
    }
    return $State
}

function Assert-ProductionConvergenceBeforeFlash {
    param([Parameter(Mandatory)]$State)
    $evidence = Load-ProductionConvergenceEvidence
    $fingerprint = Get-ProductionFirmwareInputFingerprint -State $State
    Get-ConvergenceDispatchInputs -Evidence $evidence -CurrentFirmwareInputFingerprint $fingerprint | Out-Null
    Assert-FlashAllowed `
        -FailureSet $evidence `
        -RootfsOfflinePassed ([bool]$evidence.rootfs_offline_passed) `
        -CandidateAcceptancePassed $true `
        -ContractGapState ([string]$evidence.contract_gap_state) | Out-Null
    Write-Host "PRODUCTION_CONVERGENCE_PREFLASH=PASS fingerprint=$fingerprint failure_set=$($evidence.failure_set_fingerprint)"
    return $evidence
}

function Start-ProductionFlashChain {
    param([Parameter(Mandatory)]$State)
    if ($State.PSObject.Properties.Name -contains 'flash_chain_id' -and [string]$State.flash_chain_id) {
        throw "FLASH_CHAIN_ALREADY_STARTED=$([string]$State.flash_chain_id)"
    }
    $evidence = Assert-ProductionConvergenceBeforeFlash -State $State
    $chain = Get-Sha256HexFromText -Text "run=$([long]$State.run_id)`nsource=$([string]$State.source_sha)`ncandidate=$([string]$State.candidate_sha256)"
    if ($State.PSObject.Properties.Name -contains 'flash_chain_id') { $State.flash_chain_id = $chain }
    else { Add-Member -InputObject $State -NotePropertyName flash_chain_id -NotePropertyValue $chain }
    $evidence.postflash_mutation_state = 'CLEAN'
    $evidence.contract_gap_state = 'NONE'
    Add-ConvergenceNoteProperty -Object $evidence -Name 'flash_chain_id' -Value $chain
    Add-ConvergenceNoteProperty -Object $evidence -Name 'flash_candidate_sha256' -Value ([string]$State.candidate_sha256)
    Add-ConvergenceNoteProperty -Object $evidence -Name 'flash_source_sha' -Value ([string]$State.source_sha)
    Save-ReleaseConvergenceEvidence -Evidence $evidence -Path (Get-ProductionConvergenceEvidencePath) | Out-Null
    Sync-ProductionConvergenceState -State $State -Evidence $evidence | Out-Null
    Write-Host "PRODUCTION_FLASH_CHAIN_STARTED=$chain"
    return $chain
}

function Invoke-ProductionConvergenceManager {
    param(
        [Parameter(Mandatory)][ValidateSet('IngestPostFlash','MarkMutation')][string]$Mode,
        [switch]$AllowFailure
    )
    $manager = Join-Path $PSScriptRoot 'release-convergence-manager.ps1'
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) { throw 'PRODUCTION_CONVERGENCE_MANAGER_MISSING' }
    $args = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$manager,
        '-Mode',$Mode,
        '-EvidencePath',(Get-ProductionConvergenceEvidencePath),
        '-VerificationReportPath',(Get-ProductionRealDeviceReportPath)
    )
    $result = Invoke-Process 'pwsh' $args -AllowFailure
    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        throw "PRODUCTION_CONVERGENCE_MANAGER_FAILED mode=$Mode exit=$($result.ExitCode) output=$($result.Output)"
    }
    return $result
}

function Ingest-ProductionPostFlashEvidence {
    param([Parameter(Mandatory)]$State)
    $result = Invoke-ProductionConvergenceManager -Mode IngestPostFlash -AllowFailure
    $evidence = Load-ProductionConvergenceEvidence
    Sync-ProductionConvergenceState -State $State -Evidence $evidence | Out-Null
    if ($result.ExitCode -ne 0 -and [string]$evidence.contract_gap_state -ne 'REAL_DEVICE_VERIFY_CONTRACT_GAP') {
        throw "POSTFLASH_CONVERGENCE_INGEST_FAILED exit=$($result.ExitCode) output=$($result.Output)"
    }
    return $result
}

function Mark-ProductionPostFlashMutation {
    param([Parameter(Mandatory)]$State)
    Invoke-ProductionConvergenceManager -Mode MarkMutation | Out-Null
    $evidence = Load-ProductionConvergenceEvidence
    Sync-ProductionConvergenceState -State $State -Evidence $evidence | Out-Null
    if ([string]$evidence.postflash_mutation_state -ne 'MUTATED') { throw 'POSTFLASH_MUTATION_STATE_NOT_PERSISTED' }
    Write-Host 'POSTFLASH_MUTATION_STATE=MUTATED'
}

function Assert-ProductionReleaseConvergence {
    param([Parameter(Mandatory)]$State)
    $evidence = Load-ProductionConvergenceEvidence
    if ($evidence.PSObject.Properties.Name -notcontains 'postflash_verification_result' -or [string]$evidence.postflash_verification_result -ne 'PASS') {
        throw "DENY_PRODUCTION_RELEASED reason=POSTFLASH_REAL_DEVICE_VERIFY_NOT_PASS result=$([string]$evidence.postflash_verification_result)"
    }
    if ($State.PSObject.Properties.Name -notcontains 'flash_chain_id' -or -not [string]$State.flash_chain_id) {
        throw 'DENY_PRODUCTION_RELEASED reason=FLASH_CHAIN_ID_MISSING'
    }
    if ($evidence.PSObject.Properties.Name -notcontains 'flash_chain_id' -or [string]$evidence.flash_chain_id -ne [string]$State.flash_chain_id) {
        throw 'DENY_PRODUCTION_RELEASED reason=FLASH_CHAIN_ID_MISMATCH'
    }
    $decision = Get-PostFlashReleaseDecision `
        -PostFlashMutationState ([string]$evidence.postflash_mutation_state) `
        -RealDeviceVerifyPassed $true `
        -ContractGapState ([string]$evidence.contract_gap_state)
    if ([string]$decision.action -ne 'ALLOW_PRODUCTION_RELEASED') {
        throw "DENY_PRODUCTION_RELEASED reason=$([string]$decision.reason)"
    }
    Write-Host "PRODUCTION_CLEAN_POSTFLASH=PASS flash_chain=$([string]$State.flash_chain_id)"
    return $true
}
