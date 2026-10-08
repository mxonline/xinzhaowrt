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
Assert-Equal $current.schema_version '1.2' 'operator intent must use the current scope-aware schema'
Assert-Equal ([int]$resume.schema_version) 2 'canonical production resume state must be schema v2'

$currentDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $current
Assert-Equal $current.device_write_authorized $false 'operator intent must not authorize router writes'
Assert-True ($current.intent_type -in @('PROCESS_GOVERNANCE','EXECUTE_FIRMWARE')) 'operator intent must use a recognized scope'
if ($current.firmware_execution_authorized -eq $true) {
    Assert-Equal $current.intent_type 'EXECUTE_FIRMWARE' 'authorized firmware intent must identify executable firmware work'
    Assert-Equal $current.authorization_scope 'FIRMWARE_RELEASE' 'authorized firmware intent must be limited to release'
    Assert-Equal $current.release_mode 'RELEASE_ONLY' 'current release must not authorize device mutation'
    Assert-Equal $current.automatic_flash $false 'release-only intent must disable automatic flash'
    Assert-Equal $current.sysupgrade_forbidden $true 'release-only intent must forbid sysupgrade'
    Assert-Equal $current.device_reboot_forbidden $true 'release-only intent must forbid device reboot'
    Assert-Equal ([string]$current.highest_machine_evidence.accepted_source_sha) ([string]$current.firmware_state.active_source_sha) 'highest evidence and active source must bind the same commit'
    Assert-True ($currentDecision.allowed -or $currentDecision.reason -eq 'ACTIVE_CANDIDATE_BUILD_OWNS_GATE') 'authorized firmware intent must be runnable unless an active Candidate owns BUILD'
}
else {
    Assert-Equal $current.intent_type 'PROCESS_GOVERNANCE' 'unauthorized firmware intent must be governance only'
    Assert-Equal $current.authorization_scope 'GOVERNANCE_RULES_ONLY' 'governance intent must not authorize firmware release'
    Assert-Equal $currentDecision.allowed $false 'governance-only intent must never authorize firmware mutation'
    Assert-Equal $currentDecision.reason 'FIRMWARE_EXECUTION_NOT_AUTHORIZED' 'governance-only intent must fail closed'
}

Assert-Equal $current.guardrails.resume_before_action $true 'future executable work must resume durable state before action'
Assert-Equal $current.guardrails.do_not_dispatch_duplicate_build $true 'future execution must never dispatch duplicate build work'
Assert-Equal $current.guardrails.reuse_uploaded_candidate_artifact_after_build $true 'post-build recovery must reuse accepted artifacts'
Assert-Equal $current.guardrails.live_validate_before_build_when_safe_and_applicable $true 'safe applicable validation must precede Build'
Assert-Equal $current.guardrails.exact_artifact_promotion_required $true 'promotion must retain exact artifact bytes'
Assert-Equal ([string]$current.highest_machine_evidence.authority) 'OPERATOR' 'highest machine evidence must remain operator-authorized'
Assert-Equal ([string]$current.highest_machine_evidence.priority_class) 'HIGHEST' 'current objective must retain highest machine priority'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$current.highest_machine_evidence.objective_id)) 'highest machine evidence must name its objective'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$current.highest_machine_evidence.required_terminal)) 'highest machine evidence must name its terminal state'
Assert-Equal ([string]$current.highest_machine_evidence.execution_id) ([string]$current.execution_id) 'highest machine evidence must bind the active execution'
Assert-Equal $current.highest_machine_evidence.fail_closed_on_violation $true 'highest machine evidence must fail closed on violation'
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
