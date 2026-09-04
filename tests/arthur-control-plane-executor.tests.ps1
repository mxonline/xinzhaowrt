$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-control-plane.yml'
$ScriptPath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$PipelinePath = Join-Path $Root 'ai_orchestrator\arthur.py'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

Assert-True (Test-Path $WorkflowPath) 'Arthur Control Plane workflow must exist'
Assert-True (Test-Path $ScriptPath) 'Arthur Control Plane script must exist'
Assert-True (Test-Path $PipelinePath) 'Arthur pipeline must exist'

$workflow = Get-Content -Raw $WorkflowPath
$script = Get-Content -Raw $ScriptPath
$pipeline = Get-Content -Raw $PipelinePath

Assert-True (-not $workflow.Contains("default: 'codex/arthur-runner-control-plane-20260904'")) 'schedule/workflow default must not pin the old runner feature branch'
Assert-Contains $workflow "github.event_name == 'workflow_dispatch'" 'workflow must distinguish manual source_ref from scheduled main checkout'
Assert-Contains $workflow "github.ref_name" 'scheduled control-plane runs must follow the repository branch/main instead of a stale feature branch'

Assert-Contains $script 'HEADLESS_RUNTIME_STARTED=PASS' 'recoverable control-plane state must start the existing headless ProductionRuntime'
Assert-Contains $script 'STATE_SOURCE=AI_ORCHESTRATOR' 'ai_orchestrator StateStore must be the execution checkpoint source'
Assert-Contains $script 'python -m ai_orchestrator resume' 'control plane must reuse the existing ai_orchestrator resume entrypoint'
Assert-Contains $script 'runtime-state.json' 'control plane must seed or resume the durable ai_orchestrator runtime state'
Assert-Contains $script 'RECOVERABLE_BUILD_INFO_PROVENANCE' 'build-info provenance mismatch must be classified recoverable instead of terminal watchdog-only BLOCKED'

Assert-Contains $pipeline 'ADH_MANAGEMENT' 'Arthur pipeline must carry the current ADH management checkpoint'
Assert-Contains $pipeline 'ADH_CHINESE' 'Arthur pipeline must carry the current Chinese localization checkpoint'

Write-Host 'ARTHUR_CONTROL_PLANE_EXECUTOR_CONTRACT=PASS'
