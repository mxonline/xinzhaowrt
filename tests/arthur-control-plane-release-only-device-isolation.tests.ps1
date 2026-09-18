$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RoutingPath = Join-Path $Root 'scripts\arthur-control-plane-device-routing.ps1'

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

if (-not (Test-Path -LiteralPath $RoutingPath -PathType Leaf)) {
    throw "TEST_FAIL: routing helper is missing: $RoutingPath"
}
. $RoutingPath

$ResumeStatePath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
. $ResumeStatePath

$failures = @(
    @{ name = 'offline'; error = 'DEVICE_OFFLINE' },
    @{ name = 'ssh-host-key-mismatch'; error = 'REMOTE HOST IDENTIFICATION HAS CHANGED' },
    @{ name = 'unreachable'; error = 'DEVICE_UNREACHABLE' }
)

foreach ($failure in $failures) {
    $tracker = [pscustomobject]@{ called = $false }
    $result = Invoke-ArthurControlPlaneDeviceObservation -ReleaseMode 'RELEASE_ONLY' -Action {
        $tracker.called = $true
        throw $failure.error
    }
    Assert-True (-not $tracker.called) "RELEASE_ONLY must not invoke device observation for $($failure.name)"
    Assert-True ([bool]$result.skipped) "RELEASE_ONLY must skip $($failure.name)"
    Assert-Equal ([string]$result.reason) 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED' "RELEASE_ONLY skip reason must be explicit for $($failure.name)"
}

$flashTracker = [pscustomobject]@{ called = $false }
$flashResult = Invoke-ArthurControlPlaneDeviceObservation -ReleaseMode 'FLASH_AND_VERIFY' -Action {
    $flashTracker.called = $true
    return 'probe-result'
}
Assert-True $flashTracker.called 'FLASH_AND_VERIFY must keep invoking device observation'
Assert-True (-not [bool]$flashResult.skipped) 'FLASH_AND_VERIFY must not skip device observation'
Assert-Equal ([string]$flashResult.reason) 'FLASH_AND_VERIFY_DEVICE_OBSERVATION_REQUIRED' 'FLASH_AND_VERIFY reason must remain explicit'
Assert-Equal ([string]$flashResult.value) 'probe-result' 'FLASH_AND_VERIFY must preserve the probe result'

$baseline = Get-Content -Raw -LiteralPath (Join-Path $Root 'production\real-device-baseline.json') | ConvertFrom-Json
$runtime = [pscustomobject]@{ phase='CHANGE_IMPACT'; current_stage='CHANGE_IMPACT'; next_action='CHANGE_IMPACT'; turn_count=0 }
$fallback = Resolve-ArthurResumeState `
    -RepositoryHead 'f4c0695bdefe2ff56c95613b7dd39429e619e467' `
    -RealDeviceBaseline $baseline `
    -LiveDevice $null `
    -RuntimeState $runtime `
    -AllowBaselineFallbackForMissingLiveDevice:$true `
    -ExecutionId 'arthur-v0.1.5-release-e037750-20260918'
Assert-True ([bool]$fallback.instruction_allowed) 'RELEASE_ONLY must resume from the frozen baseline without live device evidence'
Assert-Equal ([string]$fallback.device.evidence) 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED' 'RELEASE_ONLY must identify baseline fallback explicitly'

$historicalStatus = [pscustomobject]@{
    status = 'PRODUCTION_RELEASED'
    request_id = 'arthur-openclash-memory-v014'
}
$newExecutionResume = [pscustomobject]@{
    execution_id = 'arthur-v0.1.5-release-e037750-20260918'
    current_gate = 'CHANGE_IMPACT'
    next_action = 'CHANGE_IMPACT'
}
Assert-True (-not (Test-ArthurControlPlaneTerminalStatusForActiveExecution `
        -TerminalStatus $historicalStatus `
        -ResumeState $newExecutionResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918')) `
    'historical PRODUCTION_RELEASED status must not block a new RELEASE_ONLY execution'

$currentTerminalStatus = [pscustomobject]@{
    status = 'PRODUCTION_RELEASED'
    request_id = 'arthur-v0.1.5-release-e037750-20260918'
}
$currentTerminalResume = [pscustomobject]@{
    execution_id = 'arthur-v0.1.5-release-e037750-20260918'
    current_gate = 'PRODUCTION_RELEASED'
    next_action = 'NONE'
}
Assert-True (Test-ArthurControlPlaneTerminalStatusForActiveExecution `
        -TerminalStatus $currentTerminalStatus `
        -ResumeState $currentTerminalResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918') `
    'current terminal status must remain eligible for reconciliation'

$historicalSupervisorStatus = [pscustomobject]@{ status = 'TERMINAL' }
$historicalRuntimeState = [pscustomobject]@{
    phase = 'ARTIFACT'
    current_stage = 'ARTIFACT'
    terminal_state = $null
}
Assert-True (Test-ArthurControlPlaneHistoricalSupervisorStatus `
        -SupervisorStatus $historicalSupervisorStatus `
        -RuntimeState $historicalRuntimeState `
        -ResumeState $newExecutionResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918') `
    'old terminal supervisor state must be recognized as historical for a new execution'
Assert-True (Test-ArthurControlPlaneHistoricalRuntimeState `
        -RuntimeState $historicalRuntimeState `
        -ResumeState $newExecutionResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918') `
    'runtime checkpoint drift must be recognized without depending on supervisor snapshot timing'

$historicalReleasedRuntimeState = [pscustomobject]@{
    phase = 'PRODUCTION_RELEASED'
    current_stage = 'PRODUCTION_RELEASED'
    terminal_state = 'PRODUCTION_RELEASED'
}
Assert-True (Test-ArthurControlPlaneHistoricalSupervisorStatus `
        -SupervisorStatus $historicalSupervisorStatus `
        -RuntimeState $historicalReleasedRuntimeState `
        -ResumeState $newExecutionResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918') `
    'old released runtime state must not terminate a new RELEASE_ONLY execution'

$safetyBlockedRuntimeState = [pscustomobject]@{
    phase = 'RELEASE_GATE'
    current_stage = 'RELEASE_GATE'
    terminal_state = 'SAFETY_BLOCKED'
}
Assert-True (-not (Test-ArthurControlPlaneHistoricalSupervisorStatus `
        -SupervisorStatus $historicalSupervisorStatus `
        -RuntimeState $safetyBlockedRuntimeState `
        -ResumeState $newExecutionResume `
        -ExecutionId 'arthur-v0.1.5-release-e037750-20260918')) `
    'SAFETY_BLOCKED runtime state must remain fail-closed'

$controlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$controlPlane = Get-Content -Raw -LiteralPath $controlPlanePath
Assert-Contains $controlPlane 'arthur-control-plane-device-routing.ps1' 'control plane must load device routing helper'
Assert-Contains $controlPlane 'Invoke-ArthurControlPlaneDeviceObservation' 'control plane must route device observations through the mode gate'
Assert-Contains $controlPlane 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED' 'release-only skip must be observable'
Assert-Contains $controlPlane 'RETRY_DEVICE_UNAVAILABLE' 'FLASH_AND_VERIFY reachability protection must remain'
Assert-Contains $controlPlane 'Test-ArthurControlPlaneTerminalStatusForActiveExecution' 'terminal reconciliation must be execution-scoped'
Assert-Contains $controlPlane 'HISTORICAL_STATUS_DIFFERENT_EXECUTION' 'historical terminal status must be explicitly skipped'
Assert-Contains $controlPlane 'RECOVERY_SUPERVISOR_ASYNC_HANDOFF=PASS' 'historical supervisor terminal state must not block RELEASE_ONLY handoff'
Assert-Contains $controlPlane 'RUNTIME_STATE_MIGRATION=PASS' 'historical runtime state must be rebound to the active execution checkpoint'
$flashRuntime = Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts\production-agent-flash-legacy.ps1')
Assert-Contains $flashRuntime 'REMOTE HOST IDENTIFICATION HAS CHANGED' 'FLASH_AND_VERIFY legacy runtime must retain host-key safety evidence'
Assert-Contains $flashRuntime 'SSH_HOST_IDENTITY_MISMATCH' 'FLASH_AND_VERIFY legacy runtime must retain hard host-key mismatch classification'

Write-Host 'ARTHUR_RELEASE_ONLY_DEVICE_ISOLATION=PASS'
