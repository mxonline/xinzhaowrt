$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
$agentPath = Join-Path $Root 'scripts/production-agent.ps1'
$installPath = Join-Path $Root 'scripts/install-production-agent.ps1'
$pipelinePath = Join-Path $Root 'ai_orchestrator/arthur.py'
$controlPlanePath = Join-Path $Root 'scripts/arthur-control-plane.ps1'
foreach ($path in @($deployPath,$agentPath,$installPath,$pipelinePath,$controlPlanePath)) {
    if (-not (Test-Path $path)) { throw "TEST_FAIL: required rebuild routing file is missing: $path" }
}
$deploy = Get-Content -Raw $deployPath
$agent = Get-Content -Raw $agentPath
$install = Get-Content -Raw $installPath
$pipeline = Get-Content -Raw $pipelinePath
$controlPlane = Get-Content -Raw $controlPlanePath

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

# Active topology owns rebuild routing in the durable ai_orchestrator pipeline, not in a second deployment loop.
Assert-Contains $deploy 'actions: write' 'runner wakeup must retain Actions permission needed by the headless release executor'
Assert-Contains $deploy 'scripts\arthur-control-plane.ps1' 'runner wakeup must delegate to the single Control Plane'
Assert-Contains $controlPlane 'python -m ai_orchestrator resume' 'Control Plane must resume the durable executor instead of dispatching independently'
Assert-Contains $pipeline '.github/workflows/arthur-update-v3.yml' 'formal production Candidate route must remain Arthur v3'
Assert-Contains $pipeline 'RECOVERABLE_ROUTE_MISMATCH' 'non-production Candidate evidence must be rejected as recoverable route mismatch'
Assert-Contains $pipeline 'flash_allowed' 'Candidate route classification must explicitly control flash eligibility'
Assert-True ($deploy -notmatch 'REBUILD_DISPATCHING') 'wakeup workflow must not own a second rebuild-dispatch state machine'
Assert-True ($deploy -notmatch "'workflow','run'") 'wakeup workflow must not independently dispatch Candidate builds'

# REBUILD_REQUESTED still has one legacy writer for compatibility. It may persist intent, but it may not launch another controller.
$rebuildMatch = [regex]::Match($agent,'(?s)function\s+Request-CurrentSourceRebuild\b.*?(?=function\s+Invoke-RealDeviceBaselineGate\b)')
Assert-True $rebuildMatch.Success 'Request-CurrentSourceRebuild function must be present'
$rebuildFunction = $rebuildMatch.Value
Assert-Contains $rebuildFunction "Save-State `$State 'CANDIDATE_VERIFIED' 'REBUILD_REQUESTED'" 'legacy Production Agent must still durably persist a rebuild request when inspected'
Assert-Contains $rebuildFunction 'CURRENT_SOURCE_REBUILD_REQUESTED=YES' 'legacy Production Agent must expose the rebuild request marker'
Assert-True ($rebuildFunction -notmatch 'Start-Process') 'legacy Production Agent must not launch an independent Rebuild controller'
$modeRebuildNeedle = "'-Mode','Rebuild'"
Assert-True ($rebuildFunction.IndexOf($modeRebuildNeedle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'legacy Production Agent must not invoke ci-controller-v3 in Rebuild mode'

# Old runtime cleanup remains precise for rollback/forensics, but the active wakeup never installs or starts that topology.
Assert-True ($deploy -notmatch 'install-production-agent\.ps1') 'active runner wakeup must not reinstall the legacy Production Agent task'
Assert-True ($deploy -notmatch 'Start persistent v3 controller') 'active runner wakeup must not start the legacy v3 controller'
Assert-Contains $install 'Get-CimInstance Win32_Process' 'legacy installer must inspect process command lines before cleaning stale Rebuild controllers'
Assert-Contains $install 'ci-controller-v3\.ps1' 'legacy cleanup must match the Arthur v3 controller command line'
Assert-Contains $install '-Mode\s+Rebuild' 'legacy cleanup must match only Rebuild mode'
Assert-Contains $install 'Stop-Process -Id' 'legacy Rebuild controller cleanup must terminate only a verified PID'
Assert-Contains $install 'LEGACY_REBUILD_CONTROLLER_QUIESCED=PASS' 'legacy installer must expose cleanup evidence'
Assert-True ($install -notmatch '(?i)Stop-Process\s+-Name\s+(pwsh|powershell)') 'legacy cleanup must never blanket-stop PowerShell processes'

Write-Host 'REBUILD_ROUTE_OWNERSHIP_CONTRACT=PASS'
Write-Host 'SINGLE_REBUILD_DISPATCHER_CONTRACT=PASS'
Write-Host 'LEGACY_REBUILD_CONTROLLER_QUIESCE_CONTRACT=PASS'