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
Assert-Equal $current.schema_version '1.1' 'active #73 intent must use the durable execution-aware schema'
Assert-Equal $current.intent_type 'EXECUTE_FIRMWARE' 'final release must remain explicitly authorized firmware execution'
Assert-Equal $current.authorization_scope 'FIRMWARE_RELEASE' 'final release authorization must stay scope-bound'
Assert-Equal $current.firmware_execution_authorized $true 'firmware release authorization must remain durable while the external build owns BUILD'
Assert-Equal $current.execution_id 'arthur-final-release-5f41c4e-20260908' 'operator intent must bind to the active durable execution'
Assert-Equal $current.firmware_state.current_stage 'BUILD' '#73 currently owns the BUILD gate'
Assert-Equal $current.firmware_state.next_stage 'ARTIFACT' 'the only continuation after #73 BUILD is ARTIFACT'
Assert-Equal ([long]$current.firmware_state.active_run_id) 34242450515 'operator intent must bind BUILD to #73'
Assert-Equal $current.firmware_state.active_source_sha '5f41c4e25be6eb5a24f78bc794ca1d80a036087c' 'operator intent must bind #73 to the latest firmware-content baseline'
Assert-Equal $current.firmware_state.source 'KNOWN_GOOD_V3_RUN_34242450515_SOURCE_5F41C4E' 'old Build #29 recovery must not remain the active source marker'
Assert-Equal $current.guardrails.do_not_interrupt_active_run $true 'scheduled wakeups must not interrupt the active #73 build'
Assert-Equal $current.guardrails.do_not_dispatch_duplicate_build $true 'scheduled wakeups must not dispatch a duplicate build'
Assert-Equal $current.guardrails.reuse_uploaded_candidate_artifact_after_build $true 'post-build recovery must reuse the #73 artifact'
foreach ($frozen in @('WIFI','LUCI_CHINESE','ADGUARD_FULL_MANAGER','QUICKSTART')) {
    Assert-True (@($current.firmware_state.verified_frozen) -contains $frozen) "$frozen must remain accepted/frozen"
}

Assert-Equal ([int]$resume.schema_version) 2 'canonical production resume state must be schema v2'
Assert-Equal $resume.execution_id 'arthur-final-release-5f41c4e-20260908' 'resume state must share the operator execution identity'
Assert-Equal ([long]$resume.production.github_run_id) 34242450515 'resume state must bind production to #73'
Assert-Equal $resume.source.accepted_source_sha '5f41c4e25be6eb5a24f78bc794ca1d80a036087c' 'resume state must use the correct firmware-content baseline'
Assert-Equal $resume.current_gate 'BUILD' 'current durable gate must be BUILD while #73 is in progress'
Assert-Equal $resume.next_action 'BUILD' 'resume must observe the already-running BUILD rather than regress or advance early'
Assert-Equal $resume.gates.BUILD.status 'RUNNING' 'BUILD must be represented as an explicit RUNNING gate'
Assert-True (@($resume.gates.BUILD.evidence_refs) -contains 'evidence:build-run-34242450515') 'RUNNING BUILD must bind to durable GitHub evidence'
foreach ($frozen in @('WIFI','LUCI_CHINESE','ADGUARD_FULL_MANAGER','QUICKSTART')) {
    Assert-Equal $resume.gates.$frozen.status 'PASS' "$frozen must remain a first-class inherited PASS gate"
    Assert-True @($resume.gates.$frozen.evidence_refs).Count -gt 0 "$frozen PASS must carry evidence"
}
Assert-True ($null -ne $resume.PSObject.Properties['semantic_sha256']) 'durable resume state must include semantic_sha256'
Assert-True ([string]$resume.semantic_sha256 -match '^[0-9a-f]{64}$') 'durable resume semantic hash must be lowercase SHA-256'
$resumeForHash = ($resume | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
$resumeForHash.PSObject.Properties.Remove('semantic_sha256')
$resumeForHash.PSObject.Properties.Remove('evidence_timestamp')
$expectedResumeHash = Get-ArthurResumeSemanticHash $resumeForHash
Assert-Equal ([string]$resume.semantic_sha256) $expectedResumeHash 'durable resume semantic hash must match its semantic content'

$activeDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $current
Assert-Equal $activeDecision.allowed $false 'Control Plane mutation must defer while #73 owns BUILD'
Assert-Equal $activeDecision.reason 'ACTIVE_CANDIDATE_BUILD_OWNS_GATE' 'active build deferral must be explicit and machine-readable'
Assert-Equal ([long]$activeDecision.active_run_id) 34242450515 'active build deferral must preserve #73 identity'

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
Write-Host 'ARTHUR_ACTIVE_CANDIDATE_BUILD_OWNERSHIP=PASS'
Write-Host 'ARTHUR_DURABLE_EXECUTION_V2=PASS'
