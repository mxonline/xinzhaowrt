$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResumeScriptPath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$GatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$IntentPath = Join-Path $Root 'production\operator-intent.json'
$RequestPath = Join-Path $Root 'production\v3-request.json'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

. $ResumeScriptPath
$baseline = [pscustomobject]@{
    active_development_baseline = $true
    firmware = [pscustomobject]@{
        version = '0.1.3'
        build_id = '33462873812'
        source_sha = 'e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9'
    }
}
$artifactRuntime = [pscustomobject]@{ phase='ARTIFACT'; current_stage='ARTIFACT'; next_action='ARTIFACT'; turn_count=5 }
$preFlashRuntime = [pscustomobject]@{ phase='PRE_FLASH'; current_stage='PRE_FLASH'; next_action='PRE_FLASH'; turn_count=6 }
$flashRuntime = [pscustomobject]@{ phase='FLASH'; current_stage='FLASH'; next_action='FLASH'; turn_count=7 }

$artifactDefault = Resolve-ArthurResumeState -RepositoryHead ('a' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $artifactRuntime
Assert-Equal $artifactDefault.status 'STATE_RECONCILIATION_REQUIRED' 'generic ARTIFACT missing live build-info remains fail-closed'

$oldPreFlash = $env:ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK
try {
    $env:ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK = '1'

    $artifactAuthorized = Resolve-ArthurResumeState -RepositoryHead ('b' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $artifactRuntime
    Assert-Equal $artifactAuthorized.status 'RESUME_SAFE' 'exact accepted final-release ARTIFACT may use the still-unflashed accepted baseline identity'
    Assert-Equal $artifactAuthorized.instruction_allowed $true 'ARTIFACT recovery must be allowed to continue to PRE_FLASH'
    Assert-Equal $artifactAuthorized.real_device.evidence 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED' 'pre-flash fallback evidence must remain explicit'

    $preFlashAuthorized = Resolve-ArthurResumeState -RepositoryHead ('c' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $preFlashRuntime
    Assert-Equal $preFlashAuthorized.status 'RESUME_SAFE' 'exact final-release PRE_FLASH may still identify the accepted old image by frozen baseline'

    $flashBlocked = Resolve-ArthurResumeState -RepositoryHead ('d' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $flashRuntime
    Assert-Equal $flashBlocked.status 'STATE_RECONCILIATION_REQUIRED' 'pre-flash fallback must never leak into FLASH or post-flash verification'
    Assert-True (@($flashBlocked.conflicts) -contains 'REAL_DEVICE_VERSION_MISSING') 'FLASH must require live device identity evidence'
}
finally {
    $env:ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK = $oldPreFlash
}

$intent = Get-Content -Raw $IntentPath | ConvertFrom-Json
$request = Get-Content -Raw $RequestPath | ConvertFrom-Json
Assert-Equal ([string]$intent.firmware_state.current_stage) 'ARTIFACT' 'accepted Build #29 Candidate must keep operator intent at ARTIFACT'
Assert-Equal ([string]$intent.firmware_state.next_stage) 'PRE_FLASH' 'accepted Candidate must continue to PRE_FLASH'
Assert-Equal ([string]$intent.firmware_state.source) 'BUILD_29_VERIFIED_ARTIFACT_RECOVERY' 'pre-flash fallback requires the exact Build #29 recovery marker'
Assert-Contains ([string]$request.reason) 'Do not rebuild' 'final request must explicitly prohibit another Build'
Assert-Contains ([string]$request.reason) 'do not create a second Candidate' 'final request must explicitly prohibit another Candidate'
Assert-Contains ([string]$request.reason) 'rather than returning to BUILD' 'final request must prohibit regression after artifact recovery'

$gate = Get-Content -Raw $GatePath
Assert-Contains $gate 'FINAL_RELEASE_ARTIFACT_RUNTIME_MIGRATION=PASS' 'gate must move stale BUILD runtime forward to accepted ARTIFACT checkpoint'
Assert-Contains $gate "from=BUILD to=ARTIFACT" 'runtime correction must be forward-only from stale BUILD to ARTIFACT'
Assert-Contains $gate 'BUILD_29_VERIFIED_ARTIFACT_RECOVERY' 'ARTIFACT correction must be bound to the accepted recovery source marker'
Assert-Contains $gate 'ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK' 'gate must authorize missing build-info fallback only for the exact pre-flash path'
Assert-Contains $gate "currentStage -in @('ARTIFACT','PRE_FLASH')" 'pre-flash authorization must be phase-bound before FLASH'

Write-Host 'ARTHUR_FINAL_RELEASE_PREFLASH_CONTRACT=PASS'
