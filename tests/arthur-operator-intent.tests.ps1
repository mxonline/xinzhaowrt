$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IntentPath = Join-Path $Root 'production\operator-intent.json'
$RequestPath = Join-Path $Root 'production\v3-request.json'
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

foreach ($path in @($IntentPath,$RequestPath,$ResumeStatePath,$ResumeHelperPath,$IntentHelperPath,$GatePath,$ControlPlanePath,$RulesPath,$WakeupPath,$AgentsPath)) {
    Assert-True (Test-Path $path) "required Arthur control file must exist: $path"
}

. $IntentHelperPath
. $ResumeHelperPath
$current = Get-Content -Raw $IntentPath | ConvertFrom-Json
$request = Get-Content -Raw $RequestPath | ConvertFrom-Json
$resume = Get-Content -Raw $ResumeStatePath | ConvertFrom-Json

Assert-Equal $current.project 'Arthur' 'operator intent must be scoped to Arthur'
Assert-Equal $current.intent_type 'EXECUTE_FIRMWARE' 'final release must remain explicitly authorized firmware execution'
Assert-Equal $current.authorization_scope 'FIRMWARE_RELEASE' 'final release authorization must stay scope-bound'
Assert-Equal $current.firmware_execution_authorized $true 'firmware release must remain authorized'
Assert-Equal $current.firmware_state.current_stage 'ARTIFACT' 'formal Build #29 Candidate recovery has completed; current durable stage is ARTIFACT'
Assert-Equal $current.firmware_state.next_stage 'PRE_FLASH' 'the only correct continuation after accepted Candidate is PRE_FLASH'
Assert-Equal $current.firmware_state.source 'BUILD_29_VERIFIED_ARTIFACT_RECOVERY' 'ARTIFACT checkpoint must be grounded in the accepted Build #29 recovery'
foreach ($frozen in @('WIFI','LUCI_CHINESE','ADGUARD_FULL_MANAGER','QUICKSTART')) {
    Assert-True (@($current.firmware_state.verified_frozen) -contains $frozen) "$frozen must remain accepted/frozen"
}
Assert-Contains ([string]$request.reason) 'Do not rebuild' 'final request must prohibit another Build'
Assert-Contains ([string]$request.reason) 'do not create a second Candidate' 'final request must prohibit another Candidate'
Assert-Contains ([string]$request.reason) 'do not repeat feature development' 'final request must prohibit repeated accepted feature work'
Assert-Contains ([string]$request.reason) 'rather than returning to BUILD' 'artifact recovery must never regress to BUILD for missing pre-flash metadata'

# The checked-in snapshot can temporarily be STATE_RECONCILIATION_REQUIRED after a
# failed wakeup, but it must remain structurally valid so the repaired gate can
# publish the forward ARTIFACT snapshot on the next successful reconciliation.
Assert-True ($null -ne $resume.PSObject.Properties['semantic_sha256']) 'durable resume state must include semantic_sha256'
Assert-True ([string]$resume.semantic_sha256 -match '^[0-9a-f]{64}$') 'durable resume semantic hash must be lowercase SHA-256'
$resumeForHash = ($resume | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
$resumeForHash.PSObject.Properties.Remove('semantic_sha256')
$resumeForHash.PSObject.Properties.Remove('evidence_timestamp')
$expectedResumeHash = Get-ArthurResumeSemanticHash $resumeForHash
Assert-Equal ([string]$resume.semantic_sha256) $expectedResumeHash 'durable resume semantic hash must match its semantic content'
foreach ($frozen in @('wifi','luci_chinese','adguard_full_manager','quickstart')) {
    Assert-True ($null -ne $resume.verified.$frozen) "$frozen evidence must remain durable even during state reconciliation"
}

$stateOnly = [pscustomobject]@{ intent_type='STATE_CORRECTION'; authorization_scope='NONE'; firmware_execution_authorized=$false }
$stateOnlyDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $stateOnly
Assert-Equal $stateOnlyDecision.allowed $false 'state correction alone must never authorize firmware execution'
$governance = [pscustomobject]@{ intent_type='PROCESS_GOVERNANCE'; authorization_scope='GOVERNANCE_RULES_ONLY'; firmware_execution_authorized=$true }
$governanceDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $governance
Assert-Equal $governanceDecision.allowed $false 'governance scope must not leak into firmware execution'
$firmware = [pscustomobject]@{ intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true }
$firmwareDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $firmware
Assert-Equal $firmwareDecision.allowed $true 'explicit firmware-release authorization must allow the runtime'

$gate = Get-Content -Raw $GatePath
Assert-Contains $gate 'production\operator-intent.json' 'gate must read durable operator intent first'
Assert-Contains $gate 'Get-ArthurFirmwareExecutionPermission' 'gate must use scope-bound firmware permission'
Assert-Contains $gate 'FIRMWARE_EXECUTION_NOT_AUTHORIZED=PASS' 'unauthorized firmware mutation must fail closed'
Assert-Contains $gate 'FINAL_RELEASE_RUNTIME_MIGRATION=PASS' 'legacy pre-build runtime may still migrate forward to BUILD when BUILD is the accepted intent'
Assert-Contains $gate 'FINAL_RELEASE_ARTIFACT_RUNTIME_MIGRATION=PASS' 'after formal Candidate recovery the stale BUILD runtime must migrate forward to ARTIFACT'
Assert-Contains $gate 'FORMAL_BUILD29_CANDIDATE_ALREADY_ACCEPTED' 'ARTIFACT migration must record why BUILD is superseded'
Assert-Contains $gate 'BUILD_29_VERIFIED_ARTIFACT_RECOVERY' 'ARTIFACT migration must be bound to the exact accepted recovery marker'
Assert-Contains $gate 'ARTHUR_FINAL_RELEASE_PREFLASH_BASELINE_FALLBACK' 'gate must explicitly scope pre-flash baseline fallback'
Assert-Contains $gate "currentStage -in @('ARTIFACT','PRE_FLASH')" 'pre-flash fallback must stop before FLASH'
Assert-Contains $gate 'arthur-control-plane.ps1' 'authorized gate must hand off to the existing control plane'

$wakeup = Get-Content -Raw $WakeupPath
Assert-Contains $wakeup 'arthur-control-plane-gate.ps1' 'scheduled wakeup must enter through the scoped gate'
$rules = Get-Content -Raw $RulesPath
Assert-Contains $rules 'PRODUCTION_RELEASED' 'rules must preserve PRODUCTION_RELEASED as the only successful terminal'
$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'production/operator-intent.json' 'Codex startup must read operator intent before executable action selection'
Assert-Contains $agents 'EXECUTE_FIRMWARE' 'Codex must require explicit firmware execution intent'

Write-Host 'ARTHUR_OPERATOR_INTENT_GATE_CONTRACT=PASS'
Write-Host 'ARTHUR_FINAL_RELEASE_ARTIFACT_RESUME_CONTRACT=PASS'
Write-Host 'ARTHUR_CODEX_STARTUP_INTENT_CONTRACT=PASS'
