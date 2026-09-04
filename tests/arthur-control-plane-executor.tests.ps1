$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-control-plane.yml'
$WakeupWorkflowPath = Join-Path $Root '.github\workflows\production-agent-deploy.yml'
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

function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}

Assert-True (Test-Path $WorkflowPath) 'Arthur Control Plane workflow must exist'
Assert-True (Test-Path $WakeupWorkflowPath) 'runner wakeup workflow must exist'
Assert-True (Test-Path $ScriptPath) 'Arthur Control Plane script must exist'
Assert-True (Test-Path $PipelinePath) 'Arthur pipeline must exist'

$workflow = Get-Content -Raw $WorkflowPath
$wakeup = Get-Content -Raw $WakeupWorkflowPath
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

# The only unattended wakeup path must be the already proven self-hosted runner schedule.
Assert-Contains $wakeup "cron: '*/5 * * * *'" 'runner wakeup must poll every five minutes'
Assert-Contains $wakeup 'xinzhaowrt-controller' 'runner wakeup must execute on the dedicated self-hosted controller runner'
Assert-Contains $wakeup 'scripts\arthur-control-plane.ps1' 'runner wakeup must invoke the Arthur Control Plane directly'
Assert-NotContains $wakeup 'LogonType Interactive' 'runner wakeup must not depend on interactive Windows logon'
Assert-NotContains $wakeup 'XinZhaoWrt-Arthur-v3-Controller' 'legacy v3 Scheduled Task must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'install-production-agent.ps1' 'legacy Production Agent Scheduled Task installer must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'recover-existing-bridge-context.ps1' 'cross-user GUI Codex recovery must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'PRODUCTION_AGENT_AUTHENTICATED_CONTINUATION' 'legacy ten-minute continuation loop must not remain in the unattended wakeup path'

Write-Host 'ARTHUR_CONTROL_PLANE_EXECUTOR_CONTRACT=PASS'
