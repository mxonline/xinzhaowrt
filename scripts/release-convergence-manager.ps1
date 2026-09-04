param(
    [Parameter(Mandatory)]
    [ValidateSet('Freeze','Resolve','AcceptRootfs','IngestPostFlash','MarkMutation','Status')]
    [string]$Mode,
    [string]$EvidencePath = '',
    [string]$VerificationReportPath = '',
    [string]$SourceRef = 'HEAD',
    [string]$CheckId = '',
    [string]$RootCause = '',
    [string]$FirmwareSourceFix = '',
    [string]$PreflashCheckId = '',
    [string]$PreflashScriptPath = '',
    [string]$RootfsScriptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'fast-safe-release-lib.ps1')
. (Join-Path $PSScriptRoot 'fast-safe-convergence-lib.ps1')
. (Join-Path $PSScriptRoot 'release-convergence-exec-lib.ps1')

if (-not $EvidencePath) {
    if ($env:LOCALAPPDATA) {
        $EvidencePath = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff\release-convergence.json'
    } else {
        $EvidencePath = Join-Path $Root 'output/release-convergence/release-convergence.json'
    }
}
if (-not $VerificationReportPath) {
    $VerificationReportPath = Join-Path $Root 'output/real-device/real-device-verification.json'
}

function Read-VerificationReport {
    if (-not (Test-Path -LiteralPath $VerificationReportPath -PathType Leaf)) {
        throw "REAL_DEVICE_VERIFICATION_REPORT_MISSING=$VerificationReportPath"
    }
    try { return Get-Content -Raw -LiteralPath $VerificationReportPath | ConvertFrom-Json -Depth 40 }
    catch { throw "REAL_DEVICE_VERIFICATION_REPORT_INVALID: $($_.Exception.Message)" }
}

function Get-VerificationContractFingerprint {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($relative in @('scripts/real-device-verify.ps1','scripts/real-device-verify-v3.ps1')) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "VERIFICATION_CONTRACT_FILE_MISSING=$relative" }
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        $parts.Add("$relative=$sha")
    }
    return Get-Sha256HexFromText -Text ($parts -join "`n")
}

function Get-CurrentFirmwareInputFingerprint {
    $script = Join-Path $Root 'scripts/get-firmware-input-fingerprint.sh'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'FIRMWARE_INPUT_FINGERPRINT_SCRIPT_MISSING' }
    $raw = @(& bash $script $SourceRef 2>&1)
    $code = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0) { throw "FIRMWARE_INPUT_FINGERPRINT_FAILED exit=$code output=$text" }
    $fingerprint = $text.Trim()
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw "FIRMWARE_INPUT_FINGERPRINT_INVALID=$fingerprint" }
    return $fingerprint
}

function Load-RequiredEvidence {
    $evidence = Load-ReleaseConvergenceEvidence -Path $EvidencePath
    if (-not $evidence) { throw "RELEASE_CONVERGENCE_EVIDENCE_MISSING=$EvidencePath" }
    return $evidence
}

function Save-Evidence($Evidence) {
    Save-ReleaseConvergenceEvidence -Evidence $Evidence -Path $EvidencePath | Out-Null
}

switch ($Mode) {
    'Freeze' {
        $report = Read-VerificationReport
        $reportSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $VerificationReportPath).Hash.ToLowerInvariant()
        $contractSha = Get-VerificationContractFingerprint
        $evidence = Convert-RealDeviceVerificationToFailureSet `
            -Report $report `
            -VerificationContractFingerprint $contractSha `
            -VerificationReportSha256 $reportSha
        Save-Evidence $evidence
        Write-Host "FINAL_FAILURE_SET=$($evidence.state)"
        Write-Host "FAILURE_SET_FINGERPRINT=$($evidence.failure_set_fingerprint)"
        Write-Host "FAILURE_COUNT=$(@($evidence.items).Count)"
        exit 0
    }

    'Resolve' {
        foreach ($pair in @{
            CheckId=$CheckId; RootCause=$RootCause; FirmwareSourceFix=$FirmwareSourceFix;
            PreflashCheckId=$PreflashCheckId; PreflashScriptPath=$PreflashScriptPath
        }.GetEnumerator()) {
            if (-not ([string]$pair.Value).Trim()) { throw "RELEASE_CONVERGENCE_RESOLVE_ARGUMENT_REQUIRED=$($pair.Key)" }
        }
        $evidence = Load-RequiredEvidence
        $item = Resolve-ConvergenceFailureWithCheck `
            -Evidence $evidence `
            -CheckId $CheckId `
            -RootCause $RootCause `
            -FirmwareSourceFix $FirmwareSourceFix `
            -PreflashCheckId $PreflashCheckId `
            -PreflashScriptPath $PreflashScriptPath
        Save-Evidence $evidence
        Write-Host "FAILURE_RESOLUTION=PASS check_id=$($item.check_id) preflash_check_id=$($item.preflash_check_id)"
        Write-Host "FINAL_FAILURE_SET=$($evidence.state)"
        exit 0
    }

    'AcceptRootfs' {
        if (-not $RootfsScriptPath.Trim()) { throw 'ROOTFS_ACCEPTANCE_SCRIPT_REQUIRED' }
        $evidence = Load-RequiredEvidence
        $fingerprint = Get-CurrentFirmwareInputFingerprint
        Set-ConvergenceRootfsAcceptanceFromCheck `
            -Evidence $evidence `
            -RootfsScriptPath $RootfsScriptPath `
            -FirmwareInputFingerprint $fingerprint | Out-Null
        Save-Evidence $evidence
        Write-Host 'ROOTFS_OFFLINE_ACCEPTANCE=PASS'
        Write-Host "FIRMWARE_INPUT_FINGERPRINT=$fingerprint"
        exit 0
    }

    'IngestPostFlash' {
        $evidence = Load-RequiredEvidence
        $report = Read-VerificationReport
        $reportSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $VerificationReportPath).Hash.ToLowerInvariant()
        $unknown = New-Object System.Collections.Generic.List[string]
        $observed = New-Object System.Collections.Generic.List[string]
        foreach ($failure in @($report.failures)) {
            $fingerprint = Get-RealDeviceFailureFingerprint -Failure $failure
            $observed.Add($fingerprint)
            $known = @($evidence.items | Where-Object { [string]$_.failure_fingerprint -eq $fingerprint }) | Select-Object -First 1
            if (-not $known) { $unknown.Add($fingerprint) }
        }
        Add-ConvergenceNoteProperty -Object $evidence -Name 'postflash_verification_report_sha256' -Value $reportSha
        Add-ConvergenceNoteProperty -Object $evidence -Name 'postflash_verification_result' -Value ([string]$report.result).ToUpperInvariant()
        Add-ConvergenceNoteProperty -Object $evidence -Name 'postflash_failure_fingerprints' -Value @($observed.ToArray())
        if ($unknown.Count -gt 0) {
            $evidence.contract_gap_state = 'REAL_DEVICE_VERIFY_CONTRACT_GAP'
            Add-ConvergenceNoteProperty -Object $evidence -Name 'contract_gap_failures' -Value @($unknown.ToArray())
            Save-Evidence $evidence
            Write-Host "REAL_DEVICE_VERIFY_CONTRACT_GAP=YES count=$($unknown.Count)"
            exit 2
        }
        Save-Evidence $evidence
        Write-Host "POSTFLASH_FAILURE_SET=KNOWN_OR_CLEAN count=$($observed.Count)"
        Write-Host "POSTFLASH_RESULT=$([string]$report.result)"
        exit 0
    }

    'MarkMutation' {
        $evidence = Load-RequiredEvidence
        $evidence.postflash_mutation_state = 'MUTATED'
        Add-ConvergenceNoteProperty -Object $evidence -Name 'postflash_mutated_at' -Value (Get-Date).ToUniversalTime().ToString('o')
        Save-Evidence $evidence
        Write-Host 'POSTFLASH_MUTATION_STATE=MUTATED'
        exit 0
    }

    'Status' {
        $evidence = Load-RequiredEvidence
        $evidence | ConvertTo-Json -Depth 40
        exit 0
    }
}
