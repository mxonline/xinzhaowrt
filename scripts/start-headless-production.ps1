param(
    [ValidateSet('run-production','resume','status','stop')]
    [string]$Command = 'run-production',
    [ValidateSet('arthur')]
    [string]$Device = 'arthur',
    [string]$StateDir = 'output/headless-production',
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$python = (Get-Command py -ErrorAction SilentlyContinue)
if ($python) {
    & $python.Source -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) { $python = $null }
}
if (-not $python) { $python = (Get-Command python -ErrorAction SilentlyContinue) }
if (-not $python) { throw 'Python 3.10+ launcher is required.' }
if ($python.Name -ne 'py.exe') {
    & $python.Source -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.10+ launcher is required.' }
}

$arguments = @('-m', 'ai_orchestrator', $Command)
if ($python.Name -eq 'py.exe') { $arguments = @('-3') + $arguments }
if ($Command -eq 'run-production') { $arguments += @($Device, '--detach') }
$arguments += @('--state-dir', $StateDir)
if ($Foreground) { $arguments += '--foreground' }
Push-Location $RepoRoot
try {
    & $python.Source @arguments
    exit $LASTEXITCODE
}
finally { Pop-Location }
