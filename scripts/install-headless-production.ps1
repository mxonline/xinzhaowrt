param(
    [string]$TaskName = 'XinZhaoWrt-Arthur-Headless-Production',
    [string]$StateDir = 'output\headless-production'
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

$escapedStart = $StartScript.Replace("'", "''")
$escapedState = $absoluteStateDir.Replace("'", "''")
$resumeInvocation = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '$escapedStart' -Command 'resume' -StateDir '$escapedState'"
$Action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
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
Write-Host 'HEADLESS_PERSISTENT_INSTALL=PASS'
