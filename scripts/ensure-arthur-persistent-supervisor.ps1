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

function Normalize-CommandLinePath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return $Value.Replace('/', '\').TrimEnd('\')
}

function Get-MatchingSupervisorProcess {
    param(
        [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$ControlPath
    )

    $stateNeedle = Normalize-CommandLinePath $StatePath
    $controlNeedle = Normalize-CommandLinePath $ControlPath
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        $normalizedCommandLine = Normalize-CommandLinePath $commandLine
        if ($normalizedCommandLine.IndexOf('run-supervisor.py',[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        if ($normalizedCommandLine.IndexOf($stateNeedle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        if ($normalizedCommandLine.IndexOf($controlNeedle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            CommandLine = $commandLine
        }
    }
}

function Invoke-DetachedSupervisorFallback {
    param(
        [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$ControlPath,
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][string]$ShimPath
    )

    $hadRunnerTrackingId = Test-Path -LiteralPath 'Env:RUNNER_TRACKING_ID'
    $originalRunnerTrackingId = [Environment]::GetEnvironmentVariable('RUNNER_TRACKING_ID','Process')
    $hadHeadlessModel = Test-Path -LiteralPath 'Env:HEADLESS_CODEX_MODEL'
    $originalHeadlessModel = [Environment]::GetEnvironmentVariable('HEADLESS_CODEX_MODEL','Process')
    $hadControlRoot = Test-Path -LiteralPath 'Env:ARTHUR_CONTROL_PLANE_CODE_ROOT'
    $originalControlRoot = [Environment]::GetEnvironmentVariable('ARTHUR_CONTROL_PLANE_CODE_ROOT','Process')
    $hadStateDir = Test-Path -LiteralPath 'Env:ARTHUR_CONTROL_PLANE_STATE_DIR'
    $originalStateDir = [Environment]::GetEnvironmentVariable('ARTHUR_CONTROL_PLANE_STATE_DIR','Process')
    $hadHeadlessPython = Test-Path -LiteralPath 'Env:HEADLESS_PYTHON_EXE'
    $originalHeadlessPython = [Environment]::GetEnvironmentVariable('HEADLESS_PYTHON_EXE','Process')

    try {
        $env:RUNNER_TRACKING_ID = ''
        $env:HEADLESS_CODEX_MODEL = 'gpt-5.6-terra'
        $env:ARTHUR_CONTROL_PLANE_CODE_ROOT = $ControlPath
        $env:ARTHUR_CONTROL_PLANE_STATE_DIR = $StatePath
        $env:HEADLESS_PYTHON_EXE = $PythonPath

        $child = Start-Process `
            -FilePath $PythonPath `
            -ArgumentList @(
                ('"' + $ShimPath + '"'),
                '--state-dir',
                ('"' + $StatePath + '"'),
                '--interval',
                '30'
            ) `
            -WindowStyle Hidden `
            -PassThru `
            -ErrorAction Stop
    }
    finally {
        if ($hadRunnerTrackingId) { $env:RUNNER_TRACKING_ID = $originalRunnerTrackingId } else { Remove-Item -LiteralPath 'Env:RUNNER_TRACKING_ID' -ErrorAction SilentlyContinue }
        if ($hadHeadlessModel) { $env:HEADLESS_CODEX_MODEL = $originalHeadlessModel } else { Remove-Item -LiteralPath 'Env:HEADLESS_CODEX_MODEL' -ErrorAction SilentlyContinue }
        if ($hadControlRoot) { $env:ARTHUR_CONTROL_PLANE_CODE_ROOT = $originalControlRoot } else { Remove-Item -LiteralPath 'Env:ARTHUR_CONTROL_PLANE_CODE_ROOT' -ErrorAction SilentlyContinue }
        if ($hadStateDir) { $env:ARTHUR_CONTROL_PLANE_STATE_DIR = $originalStateDir } else { Remove-Item -LiteralPath 'Env:ARTHUR_CONTROL_PLANE_STATE_DIR' -ErrorAction SilentlyContinue }
        if ($hadHeadlessPython) { $env:HEADLESS_PYTHON_EXE = $originalHeadlessPython } else { Remove-Item -LiteralPath 'Env:HEADLESS_PYTHON_EXE' -ErrorAction SilentlyContinue }
    }

    $deadline = (Get-Date).AddSeconds(20)
    $detached = $null
    while ((Get-Date) -lt $deadline) {
        $detached = @(Get-MatchingSupervisorProcess -StatePath $StatePath -ControlPath $ControlPath)
        if ($detached.Count -gt 0) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($detached.Count -eq 0) {
        Fail "PERSISTENT_SUPERVISOR_DETACHED_NOT_RUNNING: python=$PythonPath shim=$ShimPath"
    }

    $supervisorPid = [int]$detached[0].ProcessId
    Write-Host "PERSISTENT_SUPERVISOR_DETACHED=PASS pid=$supervisorPid"
    Write-Host 'PERSISTENT_SUPERVISOR_TASK=PASS'
}

function New-CanonicalSupervisorTask {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)]$Action
    )
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
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

$matchingSupervisor = @(Get-MatchingSupervisorProcess -StatePath $statePath -ControlPath $controlPath)
if ($matchingSupervisor.Count -gt 0) {
    $supervisorPid = [int]$matchingSupervisor[0].ProcessId
    Write-Host "PERSISTENT_SUPERVISOR_DETACHED=REUSE pid=$supervisorPid"
    Write-Host 'PERSISTENT_SUPERVISOR_TASK=PASS'
    exit 0
}

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

$existing = $null
$taskLookupError = $null
try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}
catch {
    $taskLookupError = $_
}

if ($env:GITHUB_ACTIONS -eq 'true' -and ($taskLookupError -or -not $existing)) {
    Invoke-DetachedSupervisorFallback -StatePath $statePath -ControlPath $controlPath -PythonPath $pythonPath -ShimPath $shimPath
    exit 0
}

try {
$interactiveUser = ''
if ($existing -and $existing.Principal -and -not [string]::IsNullOrWhiteSpace([string]$existing.Principal.UserId)) {
    $interactiveUser = [string]$existing.Principal.UserId
    Write-Host "PERSISTENT_SUPERVISOR_INTERACTIVE_USER=REUSE user=$interactiveUser source=ScheduledTaskPrincipal"
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
    $task = New-CanonicalSupervisorTask -UserId $interactiveUser -Action $action
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=PASS task=$TaskName user=$interactiveUser"
}
elseif ($launcherDrift) {
    if ([string]$existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }
    $task = New-CanonicalSupervisorTask -UserId $interactiveUser -Action $action
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REREGISTERED=PASS task=$TaskName user=$interactiveUser"
}
else {
    Write-Host "PERSISTENT_SUPERVISOR_TASK_REGISTERED=REUSE task=$TaskName user=$interactiveUser state=$($existing.State)"
}

if ($DoNotStart) {
    $prepared = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "PERSISTENT_SUPERVISOR_TASK_PREPARED=PASS task=$TaskName user=$interactiveUser launcher=$launcherPath state=$($prepared.State)"
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

Write-Host "PERSISTENT_SUPERVISOR_TASK=PASS task=$TaskName user=$interactiveUser launcher=$launcherPath state=$($taskNow.State)"
exit 0
}
catch {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Invoke-DetachedSupervisorFallback -StatePath $statePath -ControlPath $controlPath -PythonPath $pythonPath -ShimPath $shimPath
        exit 0
    }
    throw
}
