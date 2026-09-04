$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IntentPath = Join-Path $Root 'production\operator-intent.json'
$IntentHelperPath = Join-Path $Root 'scripts\arthur-operator-intent.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
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
Assert-True (Test-Path $ControlPlanePath) 'Arthur control plane must exist'
Assert-True (Test-Path $AgentsPath) 'AGENTS rules must exist'

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

$controlPlane = Get-Content -Raw $ControlPlanePath
Assert-Contains $controlPlane 'production\operator-intent.json' 'control plane must read the durable operator intent before headless execution'
Assert-Contains $controlPlane 'Get-ArthurFirmwareExecutionPermission' 'control plane must use the scoped firmware execution decision'
Assert-Contains $controlPlane 'FIRMWARE_EXECUTION_NOT_AUTHORIZED' 'control plane must stop before headless firmware execution when permission is absent'

$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'state statement is not execution authorization' 'GPT/Codex rules must distinguish state correction from execution authorization'
Assert-Contains $agents 'authorization is scope-bound' 'GPT/Codex rules must prevent authorization leakage across tasks'
Assert-Contains $agents 'operator-intent.json' 'GPT/Codex startup must read operator intent before choosing a firmware action'

Write-Host 'ARTHUR_OPERATOR_INTENT_GATE_CONTRACT=PASS'
