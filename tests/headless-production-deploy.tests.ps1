$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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

$installerPath = Join-Path $Root 'scripts\install-headless-production.ps1'
$deployPath = Join-Path $Root '.github\workflows\headless-production-deploy.yml'
$pipelinePath = Join-Path $Root 'ai_orchestrator\arthur.py'
$startPath = Join-Path $Root 'scripts\start-headless-production.ps1'

Assert-True (Test-Path $installerPath) 'persistent headless installer is missing'
Assert-True (Test-Path $deployPath) 'headless production deploy workflow is missing'
Assert-True (Test-Path $pipelinePath) 'Arthur headless pipeline is missing'
Assert-True (Test-Path $startPath) 'headless start wrapper is missing'

$installer = Get-Content -Raw $installerPath
$deploy = Get-Content -Raw $deployPath
$pipeline = Get-Content -Raw $pipelinePath
$start = Get-Content -Raw $startPath

Assert-Contains $installer 'XinZhaoWrt-Arthur-Headless-Production' 'installer must create the persistent Arthur headless task'
Assert-Contains $installer 'Register-ScheduledTask' 'installer must register a Windows Scheduled Task'
Assert-Contains $installer 'LogonTrigger' 'installer must restart the runtime at user logon'
Assert-Contains $installer '$env:USERDOMAIN' 'task must run as the authenticated interactive user, not SYSTEM'
Assert-Contains $installer '[string]$PythonExe' 'installer must accept an explicit persistent Python interpreter path'
Assert-Contains $installer '-Execute $resolvedPython' 'scheduled task must execute the pinned Python interpreter directly'
Assert-Contains $installer '-m ai_orchestrator resume' 'scheduled task must resume persisted orchestration state'
Assert-True ($installer -notmatch '(?i)-UserId\s+["'']?(SYSTEM|LocalSystem)["'']?') 'headless runtime must not run as SYSTEM/LocalSystem'

Assert-Contains $deploy 'codex/arthur-fast-candidate' 'deploy must track the active Arthur production branch'
Assert-Contains $deploy 'self-hosted' 'deploy must use the persistent Windows controller runner'
Assert-Contains $deploy 'xinzhaowrt-controller' 'deploy must bind the existing controller runner label'
Assert-Contains $deploy '$env:GITHUB_WORKSPACE' 'deploy must sync from the already checked-out workspace'
Assert-Contains $deploy 'astral-sh/setup-uv@v6' 'deploy must bootstrap uv without requiring machine-global Python'
Assert-Contains $deploy 'uv python install 3.12' 'deploy must install a managed Python 3.12 runtime'
Assert-Contains $deploy 'XinZhaoWrt\HeadlessPython' 'managed Python and venv must live in a persistent user-writable location'
Assert-Contains $deploy 'uv venv' 'deploy must create a persistent headless virtual environment'
Assert-Contains $deploy 'uv pip install --python $pythonExe' 'deploy must install dependencies into the exact persistent interpreter'
Assert-Contains $deploy 'requirements-headless.txt' 'deploy must use the project headless dependency input'
Assert-Contains $deploy '-PythonExe $pythonExe' 'deploy must pass the persistent interpreter path into the scheduled task installer'
Assert-Contains $deploy 'gh auth status' 'deploy must verify persistent GitHub authentication'
Assert-Contains $deploy 'install-headless-production.ps1' 'deploy must install/start the headless daemon task'
Assert-Contains $deploy 'ai_orchestrator/**' 'orchestrator changes must redeploy the daemon'
Assert-Contains $deploy 'scripts/start-headless-production.ps1' 'start-wrapper changes must redeploy the daemon'

$workIndex = $pipeline.IndexOf('CHANGESET_IMPLEMENTATION',[System.StringComparison]::Ordinal)
$freezeIndex = $pipeline.IndexOf('CHANGESET_FREEZE',[System.StringComparison]::Ordinal)
$gateIndex = $pipeline.IndexOf('IMPLEMENTATION_COMPLETE_GATE',[System.StringComparison]::Ordinal)
$buildIndex = $pipeline.IndexOf('"BUILD"',[System.StringComparison]::Ordinal)
Assert-True ($workIndex -ge 0) 'Arthur pipeline must include CHANGESET_IMPLEMENTATION'
Assert-True ($freezeIndex -ge 0) 'Arthur pipeline must include CHANGESET_FREEZE'
Assert-True ($gateIndex -ge 0) 'Arthur pipeline must include IMPLEMENTATION_COMPLETE_GATE'
Assert-True ($buildIndex -ge 0) 'Arthur pipeline must include BUILD'
Assert-True ($workIndex -lt $freezeIndex) 'changeset implementation must finish before freeze'
Assert-True ($freezeIndex -lt $gateIndex) 'state-only freeze must occur before the candidate hard gate'
Assert-True ($gateIndex -lt $buildIndex) 'candidate hard gate must pass before production build'

Assert-Contains $start "'resume'" 'start wrapper must expose resume mode'

Write-Host 'HEADLESS_PERSISTENCE_CONTRACT=PASS'
Write-Host 'HEADLESS_UV_PYTHON_BOOTSTRAP_CONTRACT=PASS'
Write-Host 'V4_3_IMPLEMENTATION_GATE_ORDER=PASS'
Write-Host 'UNATTENDED_PRODUCTION_RESUME_CONTRACT=PASS'
