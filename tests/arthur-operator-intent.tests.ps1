$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IntentPath = Join-Path $Root 'production\operator-intent.json'
$RequestPath = Join-Path $Root 'production\v3-request.json'
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

Assert-True (Test-Path $IntentPath) 'machine-readable operator intent must exist'
Assert-True (Test-Path $RequestPath) 'final Arthur v3 release request must exist'
Assert-True (Test-Path $IntentHelperPath) 'operator intent helper must exist'
Assert-True (Test-Path $GatePath) 'scoped control-plane gate must exist'
Assert-True (Test-Path $ControlPlanePath) 'Arthur control plane must exist'
Assert-True (Test-Path $RulesPath) 'durable GPT firmware rules must exist'
Assert-True (Test-Path $WakeupPath) 'runner wakeup workflow must exist'
Assert-True (Test-Path $AgentsPath) 'Codex project startup rules must exist'

. $IntentHelperPath

$current = Get-Content -Raw $IntentPath | ConvertFrom-Json
$request = Get-Content -Raw $RequestPath | ConvertFrom-Json
Assert-Equal $current.project 'Arthur' 'operator intent must be scoped to Arthur'
if ($current.firmware_execution_authorized -eq $true) {
    Assert-Equal $current.intent_type 'EXECUTE_FIRMWARE' 'authorized firmware execution must use EXECUTE_FIRMWARE intent'
    Assert-Equal $current.authorization_scope 'FIRMWARE_RELEASE' 'authorized firmware execution must stay scoped to FIRMWARE_RELEASE'
}
else {
    Assert-Equal $current.intent_type 'PROCESS_GOVERNANCE' 'non-firmware operator intent must remain process governance-only'
    Assert-Equal $current.authorization_scope 'GOVERNANCE_RULES_ONLY' 'non-firmware operator intent must remain governance-only'
}

Assert-Equal $current.firmware_state.current_stage 'BUILD' 'final release must resume at BUILD instead of repeating ADH/LuCI development'
Assert-Equal $current.firmware_state.next_stage 'ARTIFACT' 'after BUILD the next formal release stage is ARTIFACT'
foreach ($frozen in @('WIFI','LUCI_CHINESE','ADGUARD_FULL_MANAGER','QUICKSTART')) {
    Assert-True (@($current.firmware_state.verified_frozen) -contains $frozen) "$frozen must remain accepted/frozen"
}
Assert-Contains ([string]$request.reason) 'Do not repeat feature development' 'final release request must forbid repeating accepted feature development'
Assert-Contains ([string]$request.reason) 'replacement Candidate' 'final release request must continue via one replacement Candidate'

$stateOnly = [pscustomobject]@{
    intent_type = 'STATE_CORRECTION'
    authorization_scope = 'NONE'
    firmware_execution_authorized = $false
}
$stateOnlyDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $stateOnly
Assert-Equal $stateOnlyDecision.allowed $false 'a state correction must never authorize firmware execution'
Assert-Equal $stateOnlyDecision.reason 'FIRMWARE_EXECUTION_NOT_AUTHORIZED' 'state correction denial must be explicit'

$governance = [pscustomobject]@{
    intent_type = 'PROCESS_GOVERNANCE'
    authorization_scope = 'GOVERNANCE_RULES_ONLY'
    firmware_execution_authorized = $true
}
$governanceDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $governance
Assert-Equal $governanceDecision.allowed $false 'authorization for governance work must not leak into firmware execution'
Assert-Equal $governanceDecision.reason 'AUTHORIZATION_SCOPE_MISMATCH' 'scope mismatch must be explicit'

$firmware = [pscustomobject]@{
    intent_type = 'EXECUTE_FIRMWARE'
    authorization_scope = 'FIRMWARE_RELEASE'
    firmware_execution_authorized = $true
}
$firmwareDecision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $firmware
Assert-Equal $firmwareDecision.allowed $true 'explicit firmware-release authorization must allow the firmware runtime'
Assert-Equal $firmwareDecision.reason 'FIRMWARE_EXECUTION_AUTHORIZED' 'authorized firmware decision must be explicit'

$gate = Get-Content -Raw $GatePath
Assert-Contains $gate 'production\operator-intent.json' 'gate must read durable operator intent before the control plane'
Assert-Contains $gate 'Get-ArthurFirmwareExecutionPermission' 'gate must use the scoped firmware execution decision'
Assert-Contains $gate 'FIRMWARE_EXECUTION_NOT_AUTHORIZED=PASS' 'gate must stop before firmware execution when permission is absent'
Assert-Contains $gate 'CONTROL_PLANE_MUTATION_SKIPPED=PASS' 'denied firmware execution must be explicitly non-mutating'
Assert-Contains $gate 'arthur-control-plane.ps1' 'authorized gate must hand off to the existing control plane rather than replace it'
Assert-Contains $gate 'FINAL_RELEASE_RUNTIME_MIGRATION=PASS' 'existing control-plane gate must migrate stale pre-build runtime state to the final BUILD checkpoint'
Assert-Contains $gate 'forensic -> root cause -> auto-fix -> rebuild -> PRE_FLASH_READY' 'migrated Codex prompt must resume the interrupted forensic-to-pre-flash task'
Assert-Contains $gate 'production\v3-request.json' 'runtime migration must be grounded in the durable final release request'
Assert-Contains $gate 'ADH_MANAGEMENT' 'migration must recognize the known stale ADH runtime checkpoint'
Assert-Contains $gate "phase = 'BUILD'" 'migration must set the persistent runtime phase to BUILD'

$wakeup = Get-Content -Raw $WakeupPath
Assert-Contains $wakeup 'arthur-control-plane-gate.ps1' 'scheduled wakeup must enter through the scoped operator-intent gate'

$rules = Get-Content -Raw $RulesPath
Assert-Contains $rules 'state statement is not execution authorization' 'durable GPT rules must distinguish state correction from execution authorization'
Assert-Contains $rules 'authorization is scope-bound' 'durable GPT rules must prevent authorization leakage across tasks'
Assert-Contains $rules 'operator-intent.json' 'durable GPT startup must read operator intent before choosing a firmware action'
Assert-Contains $rules 'PRODUCTION_RELEASED' 'rules must preserve the only successful terminal state'

$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'production/operator-intent.json' 'Codex startup must read operator intent before resume-state or executable firmware action selection'
Assert-Contains $agents 'state statement is not execution authorization' 'Codex project rules must distinguish state correction from execution authorization'
Assert-Contains $agents 'authorization is scope-bound' 'Codex project rules must prevent authorization leakage across tasks'
Assert-Contains $agents 'GOVERNANCE_RULES_ONLY' 'Codex must understand governance-only authorization cannot unlock firmware execution'
Assert-Contains $agents 'EXECUTE_FIRMWARE' 'Codex must require explicit firmware execution intent before mutating the release task'

Write-Host 'ARTHUR_OPERATOR_INTENT_GATE_CONTRACT=PASS'
Write-Host 'ARTHUR_FINAL_RELEASE_RUNTIME_MIGRATION_CONTRACT=PASS'
Write-Host 'ARTHUR_CODEX_STARTUP_INTENT_CONTRACT=PASS'
