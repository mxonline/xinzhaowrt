$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
$autoTriggerPath = Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml'
$agentPath = Join-Path $Root 'scripts/production-agent.ps1'
$installPath = Join-Path $Root 'scripts/install-production-agent.ps1'
if (-not (Test-Path $deployPath)) { throw 'TEST_FAIL: runner wakeup workflow is missing' }
if (-not (Test-Path $autoTriggerPath)) { throw 'TEST_FAIL: Arthur v3 auto-trigger workflow is missing' }
if (-not (Test-Path $agentPath)) { throw 'TEST_FAIL: production-agent script is missing' }
if (-not (Test-Path $installPath)) { throw 'TEST_FAIL: production-agent installer is missing' }
$deploy = Get-Content -Raw $deployPath
$autoTrigger = Get-Content -Raw $autoTriggerPath
$agent = Get-Content -Raw $agentPath
$install = Get-Content -Raw $installPath

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

# Replacement Candidate dispatch is owned by the mature v3 auto-trigger. The runner wakeup must never be a second dispatcher.
Assert-Contains $autoTrigger 'actions: write' 'v3 auto-trigger must be allowed to dispatch the formal Arthur Candidate workflow'
Assert-Contains $autoTrigger 'resolve-candidate-dedup.sh' 'Candidate dispatch must run the fingerprint dedup gate before workflow_dispatch'
Assert-Contains $autoTrigger 'WATCH_EXISTING_RUN' 'an existing matching Candidate run must be watched rather than dispatched twice'
Assert-Contains $autoTrigger 'REUSE_ARTIFACT' 'a completed matching Candidate artifact must be reused'
Assert-Contains $autoTrigger 'NO_NEW_CANDIDATE' 'no firmware-impact change must suppress a new Candidate'
Assert-Contains $autoTrigger 'NEW_CANDIDATE' 'only a new fingerprint may reach workflow dispatch'
Assert-Contains $autoTrigger 'gh workflow run arthur-update-v3.yml' 'the sole Candidate dispatcher must target the formal Arthur v3 workflow'
Assert-Contains $autoTrigger 'gh run list' 'Candidate dispatch must confirm the replacement run exists before acknowledgement'
Assert-Contains $autoTrigger 'headSha' 'replacement run confirmation must bind to the resolved source SHA'
Assert-Contains $autoTrigger 'CONFIRMED_RUN' 'replacement run id must be captured before dispatch acknowledgement'
Assert-Contains $autoTrigger 'V3_AUTO_TRIGGER_DISPATCH_ACK_TIMEOUT' 'missing dispatch acknowledgement must fail closed instead of pretending success'
Assert-Contains $autoTrigger 'V3_AUTO_TRIGGER_DISPATCHED=YES' 'successful dispatch must expose a confirmed run id'
Assert-True ($deploy -notmatch '(?i)gh\s+workflow\s+run\s+arthur-update-v3\.yml') 'runner wakeup must not own a second Candidate dispatcher'

# REBUILD_REQUESTED has one writer. Production Agent may persist the request, but it must not launch or dispatch a second controller.
$rebuildMatch = [regex]::Match($agent,'(?s)function\s+Request-CurrentSourceRebuild\b.*?(?=function\s+Invoke-RealDeviceBaselineGate\b)')
Assert-True $rebuildMatch.Success 'Request-CurrentSourceRebuild function must be present'
$rebuildFunction = $rebuildMatch.Value
Assert-Contains $rebuildFunction "Save-State `$State 'CANDIDATE_VERIFIED' 'REBUILD_REQUESTED'" 'Production Agent must durably persist the rebuild request'
Assert-Contains $rebuildFunction 'CURRENT_SOURCE_REBUILD_REQUESTED=YES' 'Production Agent must expose the rebuild request marker'
Assert-True ($rebuildFunction -notmatch 'Start-Process') 'Production Agent must not launch an independent Rebuild controller'
Assert-True ($rebuildFunction -notmatch '(?i)gh\s+workflow\s+run') 'Production Agent must not independently dispatch a Candidate workflow'
$modeRebuildNeedle = "'-Mode','Rebuild'"
Assert-True ($rebuildFunction.IndexOf($modeRebuildNeedle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Production Agent must not invoke ci-controller-v3 in Rebuild mode'

# Legacy Rebuild cleanup remains precise rollback/forensic tooling even though it is no longer in the active wakeup topology.
Assert-Contains $install 'Get-CimInstance Win32_Process' 'legacy installer must inspect process command lines to find old Rebuild controllers'
$controllerRegexNeedle = "ci-controller-v3\.ps1"
$rebuildRegexNeedle = "-Mode\s+Rebuild"
Assert-Contains $install $controllerRegexNeedle 'legacy cleanup must match only the Arthur v3 controller command line'
Assert-Contains $install $rebuildRegexNeedle 'legacy cleanup must match only Rebuild mode'
Assert-Contains $install 'Stop-Process -Id' 'legacy Rebuild controller processes must be terminated by verified PID'
Assert-Contains $install 'LEGACY_REBUILD_CONTROLLER_QUIESCED=PASS' 'legacy cleanup must expose evidence that old Rebuild writers were drained'
Assert-True ($install -notmatch '(?i)Stop-Process\s+-Name\s+(pwsh|powershell)') 'legacy cleanup must never blanket-stop PowerShell processes'

Write-Host 'REBUILD_DISPATCH_ACK_CONTRACT=PASS'
Write-Host 'SINGLE_REBUILD_DISPATCHER_CONTRACT=PASS'
Write-Host 'LEGACY_REBUILD_CONTROLLER_QUIESCE_CONTRACT=PASS'
