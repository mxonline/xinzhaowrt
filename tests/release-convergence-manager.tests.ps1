$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This test intentionally exercises executable evidence gates instead of caller-supplied pass booleans.
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

$managerPath = Join-Path $Root 'scripts/release-convergence-manager.ps1'
Assert-True (Test-Path -LiteralPath $managerPath -PathType Leaf) 'release convergence manager must exist'
$manager = Get-Content -Raw -LiteralPath $managerPath
foreach ($mode in @('Freeze','Resolve','AcceptRootfs','IngestPostFlash','MarkMutation','Status')) {
    Assert-True ($manager -match [regex]::Escape($mode)) "manager must expose mode $mode"
}
Assert-True ($manager -notmatch '(?i)PreflashPassed') 'manager must never accept a caller-supplied PreflashPassed boolean'
Assert-True ($manager -match 'real-device-verification\.json') 'Freeze/IngestPostFlash must consume the existing full real-device verification JSON'
Assert-True ($manager -match 'get-firmware-input-fingerprint\.sh') 'rootfs acceptance must bind to exact firmware inputs'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhao-convergence-manager-$PID-$([Guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $pass = Join-Path $tmp 'pass.ps1'
    $fail = Join-Path $tmp 'fail.ps1'
    Set-Content -LiteralPath $pass -Encoding UTF8 -Value "Write-Output 'PREFLASH_CHECK=PASS'; exit 0"
    Set-Content -LiteralPath $fail -Encoding UTF8 -Value "Write-Output 'PREFLASH_CHECK=FAIL'; exit 9"

    $check = Invoke-ConvergenceEvidenceCheck -CheckId 'preflash.test.pass' -ScriptPath $pass
    Assert-Equal $check.check_id 'preflash.test.pass' 'executed check preserves check id'
    Assert-Equal $check.exit_code 0 'executed preflash check must exit zero'
    Assert-True ($check.output_sha256 -match '^[0-9a-f]{64}$') 'executed check output is fingerprinted'

    Assert-Throws {
        Invoke-ConvergenceEvidenceCheck -CheckId 'preflash.test.fail' -ScriptPath $fail
    } 'CONVERGENCE_CHECK_FAILED' 'non-zero preflash check must fail closed'

    $failureSet = New-FinalFailureSet -Failures @(
        [pscustomobject][ordered]@{ check_id='after_reboot.test'; failure_fingerprint=('a' * 64); status='OPEN' }
    ) -VerificationContractFingerprint ('b' * 64)

    Resolve-ConvergenceFailureWithCheck -Evidence $failureSet `
        -CheckId 'after_reboot.test' `
        -RootCause 'root cause proven' `
        -FirmwareSourceFix 'source fix applied' `
        -PreflashCheckId 'preflash.test.pass' `
        -PreflashScriptPath $pass | Out-Null
    Assert-Equal $failureSet.state 'RESOLVED' 'failure can resolve only after executed preflash check passes'
    Assert-Equal $failureSet.items[0].preflash_check_id 'preflash.test.pass' 'resolution stores executed preflash check id'

    Set-ConvergenceRootfsAcceptanceFromCheck -Evidence $failureSet `
        -RootfsScriptPath $pass `
        -FirmwareInputFingerprint ('c' * 64) | Out-Null
    Assert-Equal $failureSet.rootfs_offline_passed $true 'rootfs acceptance requires executed check success'
    Assert-Equal $failureSet.resolved_firmware_input_fingerprint ('c' * 64) 'rootfs acceptance binds exact firmware input fingerprint'
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

Write-Host 'RELEASE_CONVERGENCE_MANAGER_EXECUTED_CHECK_CONTRACT=PASS'
Write-Host 'RELEASE_CONVERGENCE_MANAGER_NO_BOOLEAN_BYPASS_CONTRACT=PASS'
Write-Host 'RELEASE_CONVERGENCE_MANAGER_ROOTFS_BINDING_CONTRACT=PASS'
