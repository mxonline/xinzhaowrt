$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-control-plane.yml'
$WakeupWorkflowPath = Join-Path $Root '.github\workflows\production-agent-deploy.yml'
$ScriptPath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$PipelinePath = Join-Path $Root 'ai_orchestrator\arthur.py'
$RuntimePath = Join-Path $Root 'ai_orchestrator\runtime.py'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message (missing '$Needle')" }
}
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "TEST_FAIL: $Message (unexpected '$Needle')" }
}

Assert-True (Test-Path $WorkflowPath) 'Arthur Control Plane workflow must exist'
Assert-True (Test-Path $WakeupWorkflowPath) 'runner wakeup workflow must exist'
Assert-True (Test-Path $ScriptPath) 'Arthur Control Plane script must exist'
Assert-True (Test-Path $PipelinePath) 'Arthur pipeline must exist'
Assert-True (Test-Path $RuntimePath) 'ProductionRuntime must exist'

$workflow = Get-Content -Raw $WorkflowPath
$wakeup = Get-Content -Raw $WakeupWorkflowPath
$script = Get-Content -Raw $ScriptPath
$pipeline = Get-Content -Raw $PipelinePath
$runtime = Get-Content -Raw $RuntimePath

Assert-Contains $workflow 'workflow_dispatch:' 'manual Arthur Control Plane workflow must remain available for explicit recovery'
Assert-NotContains $workflow 'schedule:' 'manual Arthur Control Plane workflow must not own a second schedule'
Assert-NotContains $workflow "cron: '*/5 * * * *'" 'manual Arthur Control Plane workflow must not duplicate the runner wakeup cron'
Assert-True (-not $workflow.Contains("default: 'codex/arthur-runner-control-plane-20260904'")) 'manual workflow must not pin the old runner feature branch'

Assert-Contains $script 'HEADLESS_RUNTIME_STARTED=PASS' 'recoverable control-plane state must start the existing headless ProductionRuntime'
Assert-Contains $script 'STATE_SOURCE=AI_ORCHESTRATOR' 'ai_orchestrator StateStore must be the execution checkpoint source'
Assert-Contains $script 'python -m ai_orchestrator resume' 'control plane must reuse the existing ai_orchestrator resume entrypoint'
Assert-Contains $script 'runtime-state.json' 'control plane must seed or resume the durable ai_orchestrator runtime state'
Assert-Contains $script 'RECOVERABLE_BUILD_INFO_PROVENANCE' 'build-info provenance mismatch must be recoverable rather than terminal watchdog-only BLOCKED'
Assert-Contains $script 'Resolve-ArthurResumeState' 'control plane must preserve canonical resume-state reconciliation before runtime dispatch'
Assert-Contains $script 'instruction_allowed' 'control plane must fail closed on an unsafe resume-state conflict'
Assert-Contains $script "'tagName,isDraft,isPrerelease,publishedAt'" 'gh release list must request only fields supported by the release-list command'
Assert-NotContains $script "'tagName,isDraft,isPrerelease,publishedAt,targetCommitish'" 'gh release list must not request targetCommitish; that field is only read from release view'
Assert-Contains $script "@(`$deviceLines | Where-Object { `$_ -match 'build-info\.json' }).Count" 'single build-info match must be normalized to an array before Count under StrictMode'
Assert-Contains $script "-split '__BUILD_INFO_SCAN__', 2" 'device probe must preserve the complete multiline ubus board JSON before the build-info scan marker'
Assert-Contains $script "PSObject.Properties['board_name']" 'device identity must read OpenWrt system board_name defensively under StrictMode'
Assert-Contains $script 'DEVICE_PROBE reachable=' 'live device classification must emit explicit evidence before a safety decision'

Assert-Contains $pipeline 'ADH_MANAGEMENT' 'Arthur pipeline must carry the current ADH management checkpoint'
Assert-Contains $pipeline 'ADH_CHINESE' 'Arthur pipeline must carry the current Chinese localization checkpoint'
Assert-Contains $pipeline 'default_request_id = "arthur-adh-quickstart"' 'Arthur pipeline must own the durable current release task identity'
Assert-Contains $runtime 'self.pipeline.default_request_id' 'ProductionRuntime resume must inherit the pipeline task identity when request_id is omitted'
Assert-NotContains $runtime 'request_id or "arthur-production"' 'ProductionRuntime must not silently replace arthur-adh-quickstart with the obsolete generic task id'

Assert-Contains $wakeup "cron: '*/5 * * * *'" 'runner wakeup must execute every five minutes'
Assert-Contains $wakeup 'xinzhaowrt-controller' 'runner wakeup must execute on the dedicated self-hosted controller runner'
Assert-Contains $wakeup 'XinZhaoWrt\ControlPlane' 'headless source changes must use the canonical Control Plane root'
Assert-Contains $wakeup 'Join-Path $root ''workspace''' 'headless source changes must live in a persistent workspace across scheduled jobs'
Assert-Contains $wakeup 'ARTHUR_CONTROL_PLANE_WORKSPACE' 'wakeup must pass the persistent workspace explicitly'
Assert-Contains $wakeup 'CONTROL_PLANE_WORKSPACE_DIRTY=PRESERVED' 'dirty headless source changes must be preserved rather than cleaned'
Assert-Contains $wakeup 'merge --ff-only' 'a clean persistent workspace may only fast-forward to origin/main'
Assert-Contains $wakeup '$env:GITHUB_WORKSPACE = $env:ARTHUR_CONTROL_PLANE_WORKSPACE' 'control plane repo lookups, resume-state and Headless Codex must all bind to the persistent workspace'
Assert-Contains $wakeup 'CONTROL_PLANE_WORKSPACE_BOUND=PASS' 'runtime evidence must prove the persistent workspace binding'
Assert-NotContains $wakeup 'reset --hard' 'runner wakeup must never destroy persistent headless source changes'
Assert-NotContains $wakeup 'git clean' 'runner wakeup must never clean persistent headless source changes'
Assert-NotContains $wakeup 'actions/checkout@v4' 'active unattended source must not be replaced by an ephemeral Actions checkout'
Assert-NotContains $wakeup 'LogonType Interactive' 'runner wakeup must not depend on interactive Windows logon'
Assert-NotContains $wakeup 'XinZhaoWrt-Arthur-v3-Controller' 'legacy v3 Scheduled Task must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'install-production-agent.ps1' 'legacy Production Agent Scheduled Task installer must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'recover-existing-bridge-context.ps1' 'cross-user GUI Codex recovery must not remain in the unattended wakeup path'
Assert-NotContains $wakeup 'PRODUCTION_AGENT_AUTHENTICATED_CONTINUATION' 'legacy ten-minute continuation loop must not remain in the unattended wakeup path'

Write-Host 'ARTHUR_CONTROL_PLANE_EXECUTOR_CONTRACT=PASS'
Write-Host 'ARTHUR_PERSISTENT_WORKSPACE_CONTRACT=PASS'
Write-Host 'ARTHUR_SINGLE_SCHEDULER_CONTRACT=PASS'
Write-Host 'ARTHUR_GH_RELEASE_LIST_SCHEMA_CONTRACT=PASS'
Write-Host 'ARTHUR_SCALAR_COUNT_NORMALIZATION_CONTRACT=PASS'
Write-Host 'ARTHUR_DEVICE_PROBE_REGRESSION_CONTRACT=PASS'