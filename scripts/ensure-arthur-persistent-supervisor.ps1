[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$HeadlessPythonExe,
    [string]$TaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

$statePath = [IO.Path]::GetFullPath($StateDir)
$controlPath = [IO.Path]::GetFullPath($ControlRoot)
$pythonPath = [IO.Path]::GetFullPath($HeadlessPythonExe)
$shimPath = Join-Path $controlPath 'scripts\run-supervisor.py'

if (-not (Test-Path -LiteralPath $statePath -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $statePath | Out-Null
}
if (-not (Test-Path -LiteralPath $controlPath -PathType Container)) {
    Fail "PERSISTENT_SUPERVISOR_CONTROL_ROOT_MISSING: $controlPath"
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    Fail "PERSISTENT_SUPERVISOR_PYTHON_MISSING: $pythonPath"
}
if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
    Fail "PERSISTENT_SUPERVISOR_SHIM_MISSING: $shimPath"
}

$interactiveUser = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
if ([string]::IsNullOrWhiteSpace($interactiveUser)) {
    Fail 'PERSISTENT_SUPERVISOR_NO_INTERACTIVE_USER: Arthur Codex credentials require an active desktop user context.'
}

$launcherRoot = Join-Path $env:ProgramData 'XinZhaoWrt\PersistentSupervisor'
$launcherPath = Join-Path $launcherRoot 'run-arthur-persistent-supervisor.ps1'
New-Item -ItemType Directory -Force -Path $launcherRoot | Out-Null

function Quote-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

$launcher = @(
    '$ErrorActionPreference = ''Stop''',
    '$env:PYTHONDONTWRITEBYTECODE = ''1''',
    ('$env:HEADLESS_PYTHON_EXE = ' + (Quote-PsLiteral $pythonPath)),
    ('$env:ARTHUR_CONTROL_PLANE_CODE_ROOT = ' + (Quote-PsLiteral $controlPath)),
    ('$env:ARTHUR_CONTROL_PLANE_STATE_DIR = ' + (Quote-PsLiteral $statePath)),
    ('Set-Location -LiteralPath ' + (Quote-PsLiteral $controlPath)),
    ('& ' + (Quote-PsLiteral $pythonPath) + ' ' + (Quote-PsLiteral $shimPath) + ' --state-dir ' + (Quote-PsLiteral $statePath) + ' --interval 30'),
    'exit $LASTEXITCODE'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($launcherPath, $launcher + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`"" `
        -WorkingDirectory $launcherRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $interactiveUser
    $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Persistent Arthur GPT-Codex recovery supervisor. Runs outside the GitHub Actions process tree and resumes the existing durable release task only.'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=PASS task=$TaskName user=$interactiveUser"
}
else {
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=REUSE task=$TaskName user=$interactiveUser state=$($existing.State)"
}

$taskNow = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($taskNow.State -ne 'Running') {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}

$deadline = (Get-Date).AddSeconds(20)
$running = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $taskNow = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ($taskNow.State -eq 'Running') {
        $running = $true
        break
    }
}
if (-not $running) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $result = if ($info) { [string]$info.LastTaskResult } else { 'UNKNOWN' }
    Fail "PERSISTENT_SUPERVISOR_TASK_NOT_RUNNING: task=$TaskName state=$($taskNow.State) last_result=$result"
}

Write-Host "PERSISTENT_SUPERVISOR_TASK=PASS task=$TaskName user=$interactiveUser launcher=$launcherPath state=$($taskNow.State)"
exit 0
