$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResumeScriptPath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$ControlPlaneGatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'

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

Assert-True (Test-Path $ResumeScriptPath) 'canonical Arthur resume-state helper must exist'
Assert-True (Test-Path $ControlPlanePath) 'Arthur control plane must exist'
Assert-True (Test-Path $ControlPlaneGatePath) 'Arthur control-plane gate must exist'

. $ResumeScriptPath

$baseline = [pscustomobject]@{
    active_development_baseline = $true
    firmware = [pscustomobject]@{
        version = '0.1.3'
        build_id = '33462873812'
        source_sha = 'e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9'
    }
}
$live013 = [pscustomobject]@{
    version = '0.1.3'
    build_id = '33462873812'
    git_commit = 'e27bafa'
}
$runtimeAdh = [pscustomobject]@{
    phase = 'ADH_MANAGEMENT'
    current_stage = 'ADH_MANAGEMENT'
    next_action = 'ADH_MANAGEMENT'
    turn_count = 9
}

$safe = Resolve-ArthurResumeState -RepositoryHead ('a' * 40) -RealDeviceBaseline $baseline -LiveDevice $live013 -RuntimeState $runtimeAdh
Assert-Equal $safe.status 'RESUME_SAFE' 'matching live 0.1.3 baseline must be safe to resume'
Assert-Equal $safe.instruction_allowed $true 'safe reconciled state must allow Codex instruction generation'
Assert-Equal $safe.real_device.version '0.1.3' 'live 0.1.3 must remain the forward-development version'
Assert-Equal $safe.checkpoint.current 'ADH_MANAGEMENT' 'runtime checkpoint must be canonical'
Assert-Equal $safe.next_action 'ADH_MANAGEMENT' 'next action must come from runtime state'
Assert-Equal $safe.legacy_source_policy 'AUXILIARY_ONLY' 'historical docs must never be authoritative for current progress'

# The current Arthur can be positively identified even when its generated build-info file is missing.
# That is a recoverable metadata/provenance defect, not a reason to crash before Codex can repair it.
$missingLive = Resolve-ArthurResumeState -RepositoryHead ('e' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $runtimeAdh -AllowBaselineFallbackForMissingLiveDevice
Assert-Equal $missingLive.status 'RESUME_SAFE' 'identified current Arthur with missing build-info must remain resumable for provenance repair'
Assert-Equal $missingLive.instruction_allowed $true 'recoverable missing build-info must allow the existing ADH repair runtime to start'
Assert-Equal $missingLive.real_device.version '0.1.3' 'fallback must retain the accepted physical 0.1.3 baseline version'
Assert-Equal $missingLive.real_device.evidence 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED' 'fallback must be explicit and must not masquerade as parsed live build-info'

# Final release BUILD is normally fail-closed when live build-info is missing. The
# exact final-release gate may pass a process-local authorization context only after
# it has validated operator intent plus the durable final-release request. The
# resolver must still restrict that context to BUILD, so post-flash/release identity
# can never inherit this fallback.
$runtimeBuild = [pscustomobject]@{
    phase = 'BUILD'
    current_stage = 'BUILD'
    next_action = 'BUILD'
    turn_count = 5
}
$missingBuildDefault = Resolve-ArthurResumeState -RepositoryHead ('f' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $runtimeBuild
Assert-Equal $missingBuildDefault.status 'STATE_RECONCILIATION_REQUIRED' 'BUILD missing live build-info must remain fail-closed without exact final-release authorization'
Assert-Equal $missingBuildDefault.instruction_allowed $false 'generic BUILD must not receive baseline fallback implicitly'
Assert-True (@($missingBuildDefault.conflicts) -contains 'REAL_DEVICE_VERSION_MISSING') 'generic BUILD missing build-info conflict must remain explicit'

$oldFallbackContext = $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK
try {
    $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK = '1'
    $missingBuildAuthorized = Resolve-ArthurResumeState -RepositoryHead ('f' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $runtimeBuild
    Assert-Equal $missingBuildAuthorized.status 'RESUME_SAFE' 'exact final-release BUILD context may reuse accepted baseline only to start provenance repair'
    Assert-Equal $missingBuildAuthorized.instruction_allowed $true 'authorized final-release BUILD must be able to start the repair runtime'
    Assert-Equal $missingBuildAuthorized.real_device.evidence 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED' 'authorized BUILD fallback must remain visibly distinguishable from live build-info'
}
finally {
    $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK = $oldFallbackContext
}

$runtimeArtifact = [pscustomobject]@{
    phase = 'ARTIFACT'
    current_stage = 'ARTIFACT'
    next_action = 'ARTIFACT'
    turn_count = 6
}
$oldFallbackContext = $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK
try {
    $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK = '1'
    $artifactMissingLive = Resolve-ArthurResumeState -RepositoryHead ('f' * 40) -RealDeviceBaseline $baseline -LiveDevice $null -RuntimeState $runtimeArtifact
    Assert-Equal $artifactMissingLive.status 'STATE_RECONCILIATION_REQUIRED' 'BUILD fallback authorization must not leak into ARTIFACT or any later release phase'
    Assert-Equal $artifactMissingLive.instruction_allowed $false 'post-BUILD resume identity must remain fail-closed without live evidence'
}
finally {
    $env:ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK = $oldFallbackContext
}

$runtimeChangeImpact = [pscustomobject]@{
    phase = 'CHANGE_IMPACT'
    current_stage = 'CHANGE_IMPACT'
    next_action = 'CHANGE_IMPACT'
    turn_count = 11
}
$changeImpact = Resolve-ArthurResumeState -RepositoryHead ('d' * 40) -RealDeviceBaseline $baseline -LiveDevice $live013 -RuntimeState $runtimeChangeImpact
Assert-Equal $changeImpact.status 'RESUME_SAFE' 'later normal Arthur phases must remain resumable rather than being rejected by a legacy checkpoint allowlist'

# A legacy canonical checkpoint from the old control plane must not override the current release contract.
$staleCanonical = [pscustomobject]@{
    production_task = 'arthur-adh-quickstart'
    checkpoint = [pscustomobject]@{
        current = 'REAL_DEVICE_VERIFY'
        next_action = 'REAL_DEVICE_VERIFY'
        status = 'BLOCKED_BUILD_INFO_PROVENANCE'
    }
}
$staleCheckpoint = Resolve-ArthurControlPlaneCheckpoint -ExistingCanonical $staleCanonical
Assert-Equal $staleCheckpoint.current 'ADH_MANAGEMENT' 'legacy REAL_DEVICE_VERIFY checkpoint must be superseded by the current ADH management start'
Assert-Equal $staleCheckpoint.next_action 'ADH_MANAGEMENT' 'legacy REAL_DEVICE_VERIFY next action must not block ADH_MANAGEMENT'
Assert-Equal $staleCheckpoint.status 'CURRENT_RELEASE_CONTRACT' 'superseded legacy checkpoint must be identified as the current release contract'

# A checkpoint already expressed in the current phase registry remains valid and must not be regressed.
$currentCanonical = [pscustomobject]@{
    production_task = 'arthur-adh-quickstart'
    checkpoint = [pscustomobject]@{
        current = 'ADH_CHINESE'
        next_action = 'ADH_CHINESE'
        status = 'HEADLESS_RUNTIME_RESUMED'
    }
}
$currentCheckpoint = Resolve-ArthurControlPlaneCheckpoint -ExistingCanonical $currentCanonical
Assert-Equal $currentCheckpoint.current 'ADH_CHINESE' 'valid current-task checkpoint must be preserved'
Assert-Equal $currentCheckpoint.next_action 'ADH_CHINESE' 'valid later ADH checkpoint must not regress to management'

$olderLive = [pscustomobject]@{ version = '0.1.1'; build_id = '32943895389'; git_commit = '256b186' }
$versionConflict = Resolve-ArthurResumeState -RepositoryHead ('b' * 40) -RealDeviceBaseline $baseline -LiveDevice $olderLive -RuntimeState $runtimeAdh
Assert-Equal $versionConflict.status 'STATE_RECONCILIATION_REQUIRED' 'older live version must not silently replace the accepted 0.1.3 baseline'
Assert-Equal $versionConflict.instruction_allowed $false 'version conflict must prohibit Codex instruction generation'
Assert-True (@($versionConflict.conflicts) -contains 'REAL_DEVICE_VERSION_BASELINE_MISMATCH') 'version conflict must be explicit'

$previous = [pscustomobject]@{
    checkpoint = [pscustomobject]@{ current = 'ADH_CHINESE'; next_action = 'CHANGE_IMPACT' }
}
$regressedRuntime = [pscustomobject]@{
    phase = 'ADH_MANAGEMENT'
    current_stage = 'ADH_MANAGEMENT'
    next_action = 'ADH_MANAGEMENT'
    turn_count = 10
}
$checkpointConflict = Resolve-ArthurResumeState -RepositoryHead ('c' * 40) -RealDeviceBaseline $baseline -LiveDevice $live013 -RuntimeState $regressedRuntime -PreviousResumeState $previous
Assert-Equal $checkpointConflict.status 'STATE_RECONCILIATION_REQUIRED' 'a runtime checkpoint may not regress behind the last published checkpoint'
Assert-Equal $checkpointConflict.instruction_allowed $false 'checkpoint regression must prohibit Codex instruction generation'
Assert-True (@($checkpointConflict.conflicts) -contains 'CHECKPOINT_REGRESSION') 'checkpoint regression must be explicit'

$controlPlane = Get-Content -Raw $ControlPlanePath
Assert-Contains $controlPlane 'production\resume-state.json' 'control plane must publish the canonical repository resume snapshot'
Assert-Contains $controlPlane 'Resolve-ArthurResumeState' 'control plane must reconcile state before resuming runtime'
Assert-Contains $controlPlane 'Resolve-ArthurControlPlaneCheckpoint' 'control plane must normalize stale canonical checkpoints before validating the current release phase'
Assert-Contains $controlPlane 'STATE_RECONCILIATION_REQUIRED' 'control plane must fail closed when current state conflicts'
Assert-Contains $controlPlane 'instruction_allowed' 'control plane must guard Codex/runtime dispatch on reconciled instruction permission'
Assert-Contains $controlPlane 'RESUME_STATE_PUBLISHED' 'control plane must publish a durable state marker for GPT/Codex recovery'
Assert-Contains $controlPlane 'Get-ArthurResumePhaseIndex $checkpoint.next_action' 'control plane must validate checkpoints against the canonical Arthur phase registry, not a stale hard-coded subset'

$controlPlaneGate = Get-Content -Raw $ControlPlaneGatePath
Assert-Contains $controlPlaneGate '$isFinalRelease = $false' 'gate must default final-release BUILD fallback authorization to denied'
Assert-Contains $controlPlaneGate 'ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK' 'gate must pass a process-local BUILD fallback context only after exact final-release request validation'
Assert-Contains $controlPlaneGate 'FINAL_RELEASE_BUILD_BASELINE_FALLBACK_AUTH=PASS' 'gate must emit explicit authorization evidence before handing off to the Control Plane'

$resumeHelper = Get-Content -Raw $ResumeScriptPath
Assert-Contains $resumeHelper "phase -in @('ADH_MANAGEMENT','ADH_CHINESE')" 'missing live build-info fallback must remain restricted to the ADH preview phases by default'
Assert-Contains $resumeHelper 'ARTHUR_FINAL_RELEASE_BUILD_BASELINE_FALLBACK' 'resume helper must recognize only the explicit process-local final-release BUILD context'
Assert-Contains $resumeHelper "$phase -eq 'BUILD'" 'final-release fallback context must be phase-bound to BUILD and must not leak later'
Assert-Contains $resumeHelper 'BASELINE_FALLBACK_DEVICE_IDENTITY_CONFIRMED' 'fallback evidence must remain explicit and distinguishable from parsed live build-info'

Write-Host 'ARTHUR_RESUME_STATE_CONTRACT=PASS'
