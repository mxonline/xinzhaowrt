param(
    [string]$TaskName = 'XinZhaoWrt-Arthur-Headless-Production',
    [string]$StateDir = 'output\headless-production',
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StartScript = Join-Path $RepoRoot 'scripts\start-headless-production.ps1'
if (-not (Test-Path $StartScript)) {
    throw "Headless start wrapper is missing: $StartScript"
}

# Preserve the same Windows user that owns the persistent gh/Codex credentials.
# Running the daemon as SYSTEM/LocalSystem would silently lose those credentials.
$userId = "$env:USERDOMAIN\$env:USERNAME"
if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN) -or [string]::IsNullOrWhiteSpace($env:USERNAME)) {
    throw 'NEW_CREDENTIAL_PROVISIONING: current Windows user identity is unavailable.'
}

$absoluteStateDir = if ([System.IO.Path]::IsPathRooted($StateDir)) {
    $StateDir
} else {
    Join-Path $RepoRoot $StateDir
}
New-Item -ItemType Directory -Force -Path $absoluteStateDir | Out-Null

# The persistent scheduled task must not depend on the machine-global PATH.
# Prefer the explicit interpreter bootstrapped by GitHub Actions; retain a
# local fallback only for manual installs outside the deploy workflow.
$resolvedPython = $PythonExe
if ([string]::IsNullOrWhiteSpace($resolvedPython)) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        $resolvedPython = $pythonCommand.Source
    } else {
        $py = Get-Command py -ErrorAction SilentlyContinue
        if ($py) {
            $resolvedPython = (& $py.Source -3 -c "import sys; print(sys.executable)").Trim()
        }
    }
}
if ([string]::IsNullOrWhiteSpace($resolvedPython) -or -not (Test-Path $resolvedPython)) {
    throw 'RUNTIME_REQUIRED: a persistent Python 3.10+ interpreter path is required.'
}
& $resolvedPython -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)"
if ($LASTEXITCODE -ne 0) {
    throw "RUNTIME_REQUIRED: Python 3.10+ is required. interpreter=$resolvedPython"
}

# Ask an older daemon using this same durable state directory to stop cleanly.
# The stop marker is cleared automatically by the resume command.
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript -Command stop -StateDir $absoluteStateDir | Out-Null
} catch {
    Write-Warning "Previous headless runtime stop request failed: $($_.Exception.Message)"
}
Start-Sleep -Seconds 2

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$escapedState = $absoluteStateDir.Replace('"', '\"')
# Run the pinned interpreter directly so logon/restart recovery does not rely on PATH.
$resumeInvocation = "-m ai_orchestrator resume --state-dir `"$escapedState`""
$Action = New-ScheduledTaskAction `
    -Execute $resolvedPython `
    -Argument $resumeInvocation `
    -WorkingDirectory $RepoRoot

$LogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $LogonTrigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description 'Persistent GPT/Codex Arthur production runtime. Resumes automatically until PRODUCTION_RELEASED or a whitelisted human safety gate.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop

Write-Host "HEADLESS_TASK=$TaskName"
Write-Host "HEADLESS_TASK_USER=$userId"
Write-Host "HEADLESS_TASK_STATE=$($task.State)"
Write-Host "HEADLESS_STATE_DIR=$absoluteStateDir"
Write-Host "HEADLESS_PYTHON_EXE=$resolvedPython"
Write-Host 'HEADLESS_PERSISTENT_INSTALL=PASS'
