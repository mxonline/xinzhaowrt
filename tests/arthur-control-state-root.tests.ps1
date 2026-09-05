$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptPath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$WorkflowPath = Join-Path $Root '.github\workflows\production-agent-deploy.yml'

function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message (missing '$Needle')" }
}
function Assert-NotContains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "TEST_FAIL: $Message (unexpected '$Needle')" }
}

$script = Get-Content -Raw $ScriptPath
$workflow = Get-Content -Raw $WorkflowPath

Assert-Contains $script '$controlStateRoot = $codeRoot' 'control state must be rooted in the clean current-main control checkout'
Assert-Contains $script "Join-Path `$controlStateRoot 'production\firmware-events.jsonl'" 'firmware event ledger must come from the clean control state root'
Assert-Contains $script "Join-Path `$controlStateRoot 'production\resume-state.json'" 'resume state must come from the clean control state root'
Assert-Contains $script 'CONTROL_STATE_ROOT=PASS' 'runtime must emit the chosen clean control state root'
Assert-NotContains $script "Join-Path `$env:GITHUB_WORKSPACE 'production\firmware-events.jsonl'" 'dirty persistent task workspace must not own the control ledger'
Assert-NotContains $script "Join-Path `$env:GITHUB_WORKSPACE 'production\resume-state.json'" 'dirty persistent task workspace must not own the canonical resume snapshot'
Assert-Contains $workflow 'CONTROL_PLANE_RUNTIME_INPUT=PASS' 'wakeup must continue exposing both task/control input evidence'

Write-Host 'ARTHUR_CONTROL_STATE_ROOT_CONTRACT=PASS'
