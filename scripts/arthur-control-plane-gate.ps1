[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$WorkflowRunId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$intentHelperPath = Join-Path $root 'scripts\arthur-operator-intent.ps1'
$intentPath = Join-Path $root 'production\operator-intent.json'
$resumeGatePath = Join-Path $root 'scripts\arthur-firmware-resume.ps1'
$controlPlanePath = Join-Path $root 'scripts\arthur-control-plane.ps1'

if (-not (Test-Path -LiteralPath $intentHelperPath -PathType Leaf)) {
    Write-Error 'OPERATOR_INTENT_HELPER_MISSING'
    exit 1
}
if (-not (Test-Path -LiteralPath $resumeGatePath -PathType Leaf)) {
    Write-Error 'UNIFIED_RESUME_GATE_MISSING'
    exit 1
}
if (-not (Test-Path -LiteralPath $controlPlanePath -PathType Leaf)) {
    Write-Error 'CONTROL_PLANE_MISSING'
    exit 1
}

. $intentHelperPath
$operatorIntent = Read-ArthurOperatorIntent -Path $intentPath
$decision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $operatorIntent

$firmwareState = $operatorIntent.firmware_state
$currentStage = if ($firmwareState) { [string]$firmwareState.current_stage } else { '' }
$nextStage = if ($firmwareState) { [string]$firmwareState.next_stage } else { '' }
Write-Host "OPERATOR_INTENT=PASS intent_type=$($decision.intent_type) scope=$($decision.authorization_scope) current_stage=$currentStage next_stage=$nextStage"

if (-not $decision.allowed) {
    Write-Host "FIRMWARE_EXECUTION_NOT_AUTHORIZED=PASS reason=$($decision.reason)"
    Write-Host 'CONTROL_PLANE_MUTATION_SKIPPED=PASS'
    exit 0
}

Write-Host 'FIRMWARE_EXECUTION_AUTHORIZED=PASS'
$resumeOutput = & $resumeGatePath -Repository $Repository -AllowRepositoryHeadDriftForReconciliation 2>&1 | Out-String
$resumeCode = $LASTEXITCODE
if (-not [string]::IsNullOrWhiteSpace($resumeOutput)) { Write-Host $resumeOutput.Trim() }
if ($resumeCode -ne 0) {
    Write-Error "UNIFIED_RESUME_GATE_BLOCKED: exit_code=$resumeCode"
    exit $resumeCode
}
Write-Host 'UNIFIED_RESUME_GATE=PASS'

& $controlPlanePath -Repository $Repository -WorkflowRunId $WorkflowRunId
exit $LASTEXITCODE
