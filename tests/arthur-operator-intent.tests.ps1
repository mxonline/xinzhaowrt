$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IntentPath = Join-Path $Root 'production\operator-intent.json'
$ResumeStatePath = Join-Path $Root 'production\resume-state.json'
$ResumeHelperPath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$IntentHelperPath = Join-Path $Root 'scripts\arthur-operator-intent.ps1'
$GatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$RulesPath = Join-Path $Root 'production\GPT-FIRMWARE-EXECUTION-RULES.md'
$WakeupPath = Join-Path $Root '.github\workflows\production-agent-deploy.yml'
$AgentsPath = Join-Path $Root 'AGENTS.md'

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

foreach ($path in @($IntentPath,$ResumeStatePath,$ResumeHelperPath,$IntentHelperPath,$GatePath,$ControlPlanePath,$RulesPath,$WakeupPath,$AgentsPath)) {
    Assert-True (Test-Path $path) "required Arthur control file must exist: $path"
}

. $IntentHelperPath
. $ResumeHelperPath
$current = Read-ArthurOperatorIntent -Path $IntentPath
$resume = Get-Content -Raw $ResumeStatePath | ConvertFrom-Json

Assert-Equal $current.project 'Arthur' 'operator intent must be scoped to Arthur'
Assert-Equal $current.schema_version '1.1' 'operator intent must use the durable execution-aware schema'
Assert-Equal $current.intent_type 'EXECUTE_FIRMWARE' 'operator intent must preserve firmware execution identity'
Assert-Equal $current.authorization_scope 'FIRMWARE_RELEASE' 'operator intent must preserve firmware release scope'
Assert-Equal ([int]$resume.schema_version) 2 'canonical production resume state must be schema v2'

$currentDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $current
if ($current.firmware_execution_authorized -eq $true) {
    Assert-Equal $current.release_mode 'RELEASE_ONLY' 'fresh firmware authorization must remain RELEASE_ONLY'
    Assert-Equal $current.device_write_authorized $false 'fresh firmware authorization must not authorize router writes'
    Assert-Equal $current.guardrails.automatic_flash $false 'fresh firmware authorization must keep automatic flash disabled'
    Assert-Equal $current.guardrails.sysupgrade_forbidden $true 'fresh firmware authorization must forbid sysupgrade'
    Assert-True ([string]$current.execution_id -ne [string]$resume.execution_id -or [string]$resume.status -eq 'RESUME_SAFE') 'fresh authorization may precede bootstrap, but same-execution resume must be safe'
    if ([string]$current.execution_id -eq [string]$resume.execution_id) {
        Assert-Equal $resume.status 'RESUME_SAFE' 'bootstrapped fresh execution must be resume-safe'
        Assert-Equal $resume.instruction_allowed $true 'bootstrapped fresh execution must allow continuation'
        Assert-Equal $resume.current_gate 'CHANGE_IMPACT' 'fresh execution must begin at change impact'
        Assert-Equal $resume.next_action 'CHANGE_IMPACT' 'fresh execution must schedule change impact first'
    }
    else {
        Assert-Equal $resume.status 'PRODUCTION_RELEASED' 'before bootstrap, only the previous terminal execution may remain durable'
        Assert-Equal $resume.instruction_allowed $false 'previous terminal execution must remain closed before bootstrap'
    }
    Assert-Equal $currentDecision.allowed $true 'explicit fresh firmware-release authorization must allow bootstrap/continuation'
}
else {
    Assert-Equal $current.firmware_state.current_stage 'PRODUCTION_RELEASED' 'closed firmware intent must project the terminal stage'
    Assert-Equal $current.firmware_state.next_stage 'NONE' 'closed firmware intent must close future actions'
    Assert-Equal $resume.execution_id $current.execution_id 'closed intent and resume state must share execution identity'
    Assert-Equal $resume.status 'PRODUCTION_RELEASED' 'closed resume state must be terminal'
    Assert-Equal $resume.instruction_allowed $false 'terminal resume must forbid further firmware instructions'
    Assert-Equal $resume.current_gate 'PRODUCTION_RELEASED' 'canonical current gate must be terminal'
    Assert-Equal $resume.next_action 'NONE' 'terminal resume must not reopen a release'
    Assert-True (@($resume.pending).Count -eq 0) 'terminal resume must have no pending work'
    Assert-Equal $currentDecision.allowed $false 'completed production release must not authorize another firmware mutation'
    Assert-Equal $currentDecision.reason 'FIRMWARE_EXECUTION_NOT_AUTHORIZED' 'terminal closure must be fail-closed'
}

Assert-Equal $current.guardrails.do_not_interrupt_active_run $true 'wakeups must preserve accepted execution ownership'
Assert-Equal $current.guardrails.do_not_dispatch_duplicate_build $true 'wakeups must never dispatch a duplicate build'
Assert-Equal $current.guardrails.reuse_uploaded_candidate_artifact_after_build $true 'post-build recovery must reuse accepted artifacts'
Assert-True ($null -ne $resume.PSObject.Properties['semantic_sha256']) 'durable resume state must include semantic_sha256'
Assert-True ([string]$resume.semantic_sha256 -match '^[0-9a-f]{64}$') 'durable resume semantic hash must be lowercase SHA-256'
$resumeForHash = ($resume | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
$resumeForHash.PSObject.Properties.Remove('semantic_sha256')
$resumeForHash.PSObject.Properties.Remove('evidence_timestamp')
$expectedResumeHash = Get-ArthurResumeSemanticHash $resumeForHash
Assert-Equal ([string]$resume.semantic_sha256) $expectedResumeHash 'durable resume semantic hash must match its semantic content'

$runningBuildIntent = [pscustomobject]@{
    intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true
    firmware_state=[pscustomobject]@{ current_stage='BUILD'; active_run_id=34242450515 }
    guardrails=[pscustomobject]@{ do_not_interrupt_active_run=$true }
}
$runningBuildDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $runningBuildIntent
Assert-Equal $runningBuildDecision.allowed $false 'a still-running external Candidate BUILD must continue to block duplicate mutation'
Assert-Equal $runningBuildDecision.reason 'ACTIVE_CANDIDATE_BUILD_OWNS_GATE' 'running BUILD ownership guard must remain machine-readable'
Assert-Equal ([long]$runningBuildDecision.active_run_id) 34242450515 'running BUILD ownership guard must preserve Candidate identity'

$completedBuildIntent = [pscustomobject]@{
    intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true
    firmware_state=[pscustomobject]@{ current_stage='BUILD'; active_run_id=34242450515; candidate_release_conclusion='failure' }
    guardrails=[pscustomobject]@{ do_not_interrupt_active_run=$true }
}
$completedDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $completedBuildIntent
Assert-Equal $completedDecision.allowed $true 'once the source run completion marker is durable, repair/reconciliation may resume'

$stateOnly = [pscustomobject]@{ intent_type='STATE_CORRECTION'; authorization_scope='NONE'; firmware_execution_authorized=$false }
$stateOnlyDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $stateOnly
Assert-Equal $stateOnlyDecision.allowed $false 'state correction alone must never authorize firmware execution'
$governance = [pscustomobject]@{ intent_type='PROCESS_GOVERNANCE'; authorization_scope='GOVERNANCE_RULES_ONLY'; firmware_execution_authorized=$true }
$governanceDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $governance
Assert-Equal $governanceDecision.allowed $false 'governance scope must not leak into firmware execution'
$firmware = [pscustomobject]@{ intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true }
$firmwareDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $firmware
Assert-Equal $firmwareDecision.allowed $true 'explicit firmware-release authorization with no active external owner must allow the runtime'

$gate = Get-Content -Raw $GatePath
Assert-Contains $gate 'production\operator-intent.json' 'gate must read durable operator intent first'
Assert-Contains $gate 'Get-ArthurFirmwareExecutionPermission' 'gate must use scope-bound firmware permission before Control Plane mutation'
Assert-Contains $gate 'FIRMWARE_EXECUTION_NOT_AUTHORIZED=PASS' 'deferred or unauthorized mutation must stop before Control Plane execution'
Assert-Contains $gate 'arthur-control-plane.ps1' 'authorized gate must hand off to the existing control plane'

$wakeup = Get-Content -Raw $WakeupPath
Assert-Contains $wakeup 'arthur-control-plane-gate.ps1' 'scheduled wakeup must enter through the scoped gate'
$rules = Get-Content -Raw $RulesPath
Assert-Contains $rules 'PRODUCTION_RELEASED' 'rules must preserve PRODUCTION_RELEASED as the only successful terminal'
$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'production/operator-intent.json' 'Codex startup must read operator intent before executable action selection'
Assert-Contains $agents 'EXECUTE_FIRMWARE' 'Codex must require explicit firmware execution intent'

Write-Host 'ARTHUR_OPERATOR_INTENT_GATE_CONTRACT=PASS'
Write-Host 'ARTHUR_PRE_FLASH_PROJECTION_CONTRACT=PASS'
Write-Host 'ARTHUR_ACTIVE_CANDIDATE_BUILD_OWNERSHIP=PASS'
Write-Host 'ARTHUR_DURABLE_EXECUTION_V2=PASS'
