$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IntentPath = Join-Path $Root 'production\operator-intent.json'
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
Assert-True (Test-Path $IntentHelperPath) 'operator intent helper must exist'
Assert-True (Test-Path $GatePath) 'scoped control-plane gate must exist'
Assert-True (Test-Path $ControlPlanePath) 'Arthur control plane must exist'
Assert-True (Test-Path $RulesPath) 'durable GPT firmware rules must exist'
Assert-True (Test-Path $WakeupPath) 'runner wakeup workflow must exist'
Assert-True (Test-Path $AgentsPath) 'Codex project startup rules must exist'

. $IntentHelperPath

$current = Get-Content -Raw $IntentPath | ConvertFrom-Json
Assert-Equal $current.project 'Arthur' 'operator intent must be scoped to Arthur'
Assert-Equal $current.intent_type 'PROCESS_GOVERNANCE' 'current user authorization is for governance-rule implementation, not firmware repair'
Assert-Equal $current.authorization_scope 'GOVERNANCE_RULES_ONLY' 'current authorization scope must stay bound to governance work'
Assert-Equal $current.firmware_execution_authorized $false 'firmware execution must remain unauthorized while governance rules are being implemented'
Assert-Equal $current.firmware_state.current_stage 'ADH_MANAGEMENT' 'user-corrected firmware work start must be ADH_MANAGEMENT'
Assert-Equal $current.firmware_state.next_stage 'ADH_CHINESE' 'ADH_CHINESE must be the next firmware stage'
Assert-True (@($current.firmware_state.verified_frozen) -contains 'WIFI') 'Wi-Fi must remain VERIFIED_FROZEN'

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

$wakeup = Get-Content -Raw $WakeupPath
Assert-Contains $wakeup 'arthur-control-plane-gate.ps1' 'scheduled wakeup must enter through the scoped operator-intent gate'

$rules = Get-Content -Raw $RulesPath
Assert-Contains $rules 'state statement is not execution authorization' 'durable GPT rules must distinguish state correction from execution authorization'
Assert-Contains $rules 'authorization is scope-bound' 'durable GPT rules must prevent authorization leakage across tasks'
Assert-Contains $rules 'operator-intent.json' 'durable GPT startup must read operator intent before choosing a firmware action'
Assert-Contains $rules 'ADH_MANAGEMENT' 'rules must record the current user-corrected work start'
Assert-Contains $rules 'ADH_CHINESE' 'rules must record the next ADH localization stage'
Assert-Contains $rules 'PRODUCTION_RELEASED' 'rules must preserve the only successful terminal state'

$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'production/operator-intent.json' 'Codex startup must read operator intent before resume-state or executable firmware action selection'
Assert-Contains $agents 'state statement is not execution authorization' 'Codex project rules must distinguish state correction from execution authorization'
Assert-Contains $agents 'authorization is scope-bound' 'Codex project rules must prevent authorization leakage across tasks'
Assert-Contains $agents 'GOVERNANCE_RULES_ONLY' 'Codex must understand governance-only authorization cannot unlock firmware execution'
Assert-Contains $agents 'EXECUTE_FIRMWARE' 'Codex must require explicit firmware execution intent before mutating the release task'

Write-Host 'ARTHUR_OPERATOR_INTENT_GATE_CONTRACT=PASS'
Write-Host 'ARTHUR_CODEX_STARTUP_INTENT_CONTRACT=PASS'
