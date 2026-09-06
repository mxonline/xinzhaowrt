[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$HeadlessPythonExe,
    [string]$TaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor',
    [switch]$DoNotStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Get-InteractiveDesktopUser {
    $consoleUser = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if (-not [string]::IsNullOrWhiteSpace($consoleUser)) {
        Write-Host "PERSISTENT_SUPERVISOR_INTERACTIVE_USER=PASS user=$consoleUser source=Win32_ComputerSystem"
        return $consoleUser.Trim()
    }

    $owners = New-Object System.Collections.Generic.List[string]
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)
    foreach ($shell in $shells) {
        try {
            $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwner -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace([string]$owner.User)) {
            continue
        }

        $user = [string]$owner.User
        $domain = [string]$owner.Domain
        $qualified = if ([string]::IsNullOrWhiteSpace($domain)) { $user } else { "$domain\$user" }
        if (-not $owners.Contains($qualified)) {
            $owners.Add($qualified)
        }
    }

    if ($owners.Count -eq 1) {
        $resolved = [string]$owners[0]
        Write-Host "PERSISTENT_SUPERVISOR_INTERACTIVE_USER_FALLBACK=PASS user=$resolved source=explorer.exe"
        return $resolved
    }
    if ($owners.Count -gt 1) {
        Fail "PERSISTENT_SUPERVISOR_INTERACTIVE_USER_AMBIGUOUS: users=$($owners -join ',')"
    }

    Fail 'PERSISTENT_SUPERVISOR_NO_INTERACTIVE_USER: Arthur Codex credentials require an active desktop user context.'
}

function Quote-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-CanonicalSupervisorTask {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)]$Action,
        [Parameter(Mandatory=$true)][string]$taskLogonType,
        [Parameter(Mandatory=$true)][string]$taskRunLevel
    )

    if ($taskLogonType -eq 'S4U') {
        $trigger = New-ScheduledTaskTrigger -AtStartup
    }
    else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    }
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType $taskLogonType -RunLevel $taskRunLevel
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    return New-ScheduledTask `
        -Action $Action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Persistent Arthur GPT-Codex recovery supervisor. Runs outside the GitHub Actions process tree and resumes the existing durable release task only.'
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

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$interactiveUser = ''
$taskLogonType = 'Interactive'
$taskRunLevel = 'Highest'
if ($existing -and $existing.Principal -and -not [string]::IsNullOrWhiteSpace([string]$existing.Principal.UserId)) {
    $interactiveUser = [string]$existing.Principal.UserId
    if (-not [string]::IsNullOrWhiteSpace([string]$existing.Principal.LogonType)) {
        $taskLogonType = [string]$existing.Principal.LogonType
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$existing.Principal.RunLevel)) {
        $taskRunLevel = [string]$existing.Principal.RunLevel
    }
    Write-Host "PERSISTENT_SUPERVISOR_INTERACTIVE_USER=REUSE user=$interactiveUser source=ScheduledTaskPrincipal logon=$taskLogonType runlevel=$taskRunLevel"
}
else {
    $interactiveUser = Get-InteractiveDesktopUser
}

$launcherRoot = Join-Path $env:ProgramData 'XinZhaoWrt\PersistentSupervisor'
$launcherPath = Join-Path $launcherRoot 'run-arthur-persistent-supervisor.ps1'
New-Item -ItemType Directory -Force -Path $launcherRoot | Out-Null

$launcher = @(
    '$ErrorActionPreference = ''Stop''',
    '$env:PYTHONDONTWRITEBYTECODE = ''1''',
    ('$env:HEADLESS_PYTHON_EXE = ' + (Quote-PsLiteral $pythonPath)),
    ('$env:ARTHUR_CONTROL_PLANE_CODE_ROOT = ' + (Quote-PsLiteral $controlPath)),
    ('$env:ARTHUR_CONTROL_PLANE_STATE_DIR = ' + (Quote-PsLiteral $statePath)),
    '$env:HEADLESS_CODEX_MODEL = ''gpt-5.6-terra''',
    ('Set-Location -LiteralPath ' + (Quote-PsLiteral $controlPath)),
    ('& ' + (Quote-PsLiteral $pythonPath) + ' ' + (Quote-PsLiteral $shimPath) + ' --state-dir ' + (Quote-PsLiteral $statePath) + ' --interval 30'),
    'exit $LASTEXITCODE'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($launcherPath, $launcher + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$canonicalExecute = 'powershell.exe'
$canonicalArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
$canonicalWorkingDirectory = $launcherRoot
$action = New-ScheduledTaskAction `
    -Execute $canonicalExecute `
    -Argument $canonicalArguments `
    -WorkingDirectory $canonicalWorkingDirectory

$launcherDrift = $false
if ($existing) {
    $existingAction = @($existing.Actions | Select-Object -First 1)[0]
    if (-not $existingAction) {
        $launcherDrift = $true
    }
    else {
        $launcherDrift = (
            [string]$existingAction.Execute -ine $canonicalExecute -or
            [string]$existingAction.Arguments -ine $canonicalArguments -or
            [string]$existingAction.WorkingDirectory -ine $canonicalWorkingDirectory
        )
    }
}

if (-not $existing) {
    $task = New-CanonicalSupervisorTask -UserId $interactiveUser -Action $action -taskLogonType $taskLogonType -taskRunLevel $taskRunLevel
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=PASS task=$TaskName user=$interactiveUser logon=$taskLogonType runlevel=$taskRunLevel"
}
elseif ($launcherDrift) {
    if ([string]$existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }
    $task = New-CanonicalSupervisorTask -UserId $interactiveUser -Action $action -taskLogonType $taskLogonType -taskRunLevel $taskRunLevel
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REREGISTERED=PASS task=$TaskName user=$interactiveUser logon=$taskLogonType runlevel=$taskRunLevel"
}
else {
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=REUSE task=$TaskName user=$interactiveUser state=$($existing.State) logon=$taskLogonType runlevel=$taskRunLevel"
}

if ($DoNotStart) {
    $prepared = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "PERSISTENT_SUPERVISOR_TASK_PREPARED=PASS task=$TaskName user=$interactiveUser launcher=$launcherPath state=$($prepared.State) logon=$taskLogonType runlevel=$taskRunLevel"
    exit 0
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

Write-Host "PERSISTENT_SUPERVISOR_TASK=PASS task=$TaskName user=$interactiveUser launcher=$launcherPath state=$($taskNow.State) logon=$taskLogonType runlevel=$taskRunLevel"
exit 0
