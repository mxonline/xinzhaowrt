[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$HeadlessPythonExe,
    [ValidateSet('DiagnosticOnly','WhitelistRepair','FullRecovery')]
    [string]$Mode = 'DiagnosticOnly',
    [string]$SupervisorTaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor',
    [string]$RepairTaskName = 'XinZhaoWrt-Arthur-Repair-Controller',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Quote-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-ArthurRepairTaskActionDrift {
    param(
        $ExistingAction,
        [Parameter(Mandatory=$true)][string]$ExpectedExecute,
        [Parameter(Mandatory=$true)][string]$ExpectedArguments,
        [Parameter(Mandatory=$true)][string]$ExpectedWorkingDirectory
    )
    if (-not $ExistingAction) { return $true }
    return (
        [string]$ExistingAction.Execute -ine $ExpectedExecute -or
        [string]$ExistingAction.Arguments -ine $ExpectedArguments -or
        [string]$ExistingAction.WorkingDirectory -ine $ExpectedWorkingDirectory
    )
}

if ($env:ARTHUR_REPAIR_TASK_IMPORT_ONLY -eq '1') { return }

$statePath = [IO.Path]::GetFullPath($StateDir)
$controlPath = [IO.Path]::GetFullPath($ControlRoot)
$pythonPath = [IO.Path]::GetFullPath($HeadlessPythonExe)
$controllerPath = Join-Path $controlPath 'scripts\arthur-windows-repair-controller.ps1'

if (-not (Test-Path -LiteralPath $statePath -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $statePath | Out-Null
}
if (-not (Test-Path -LiteralPath $controlPath -PathType Container)) {
    Fail "REPAIR_CONTROLLER_CONTROL_ROOT_MISSING: $controlPath"
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    Fail "REPAIR_CONTROLLER_PYTHON_MISSING: $pythonPath"
}
if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
    Fail "REPAIR_CONTROLLER_SCRIPT_MISSING: $controllerPath"
}

$supervisor = Get-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction SilentlyContinue
if (-not $supervisor) {
    Fail "REPAIR_CONTROLLER_SUPERVISOR_TASK_MISSING: $SupervisorTaskName"
}
if (-not $supervisor.Principal -or [string]::IsNullOrWhiteSpace([string]$supervisor.Principal.UserId)) {
    Fail "REPAIR_CONTROLLER_SUPERVISOR_PRINCIPAL_MISSING: $SupervisorTaskName"
}
$interactiveUser = [string]$supervisor.Principal.UserId
Write-Host "REPAIR_CONTROLLER_INTERACTIVE_USER=PASS user=$interactiveUser source=SupervisorPrincipal"

$launcherRoot = Join-Path $env:ProgramData 'XinZhaoWrt\RepairController'
$launcherPath = Join-Path $launcherRoot 'run-arthur-repair-controller.ps1'
New-Item -ItemType Directory -Force -Path $launcherRoot | Out-Null

$launcher = @(
    '$ErrorActionPreference = ''Stop''',
    '$env:PYTHONDONTWRITEBYTECODE = ''1''',
    ('$env:HEADLESS_PYTHON_EXE = ' + (Quote-PsLiteral $pythonPath)),
    ('$env:ARTHUR_CONTROL_PLANE_CODE_ROOT = ' + (Quote-PsLiteral $controlPath)),
    ('$env:ARTHUR_CONTROL_PLANE_STATE_DIR = ' + (Quote-PsLiteral $statePath)),
    '$env:HEADLESS_CODEX_MODEL = ''gpt-5.6-terra''',
    ('Set-Location -LiteralPath ' + (Quote-PsLiteral $controlPath)),
    ('& ' + (Quote-PsLiteral $controllerPath) +
        ' -StateDir ' + (Quote-PsLiteral $statePath) +
        ' -ControlRoot ' + (Quote-PsLiteral $controlPath) +
        ' -HeadlessPythonExe ' + (Quote-PsLiteral $pythonPath) +
        ' -Mode ' + (Quote-PsLiteral $Mode) +
        ' -SupervisorTaskName ' + (Quote-PsLiteral $SupervisorTaskName) +
        ' -RepairTaskName ' + (Quote-PsLiteral $RepairTaskName)),
    'exit $LASTEXITCODE'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($launcherPath, $launcher + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$expectedExecute = 'powershell.exe'
$expectedArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
$expectedWorkingDirectory = $launcherRoot
$canonicalAction = New-ScheduledTaskAction `
    -Execute $expectedExecute `
    -Argument $expectedArguments `
    -WorkingDirectory $expectedWorkingDirectory
$canonicalPrincipal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Highest
$canonicalSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

$existingRepairTask = Get-ScheduledTask -TaskName $RepairTaskName -ErrorAction SilentlyContinue
$repairTaskDrift = $false
if ($existingRepairTask) {
    $existingAction = @($existingRepairTask.Actions | Select-Object -First 1)[0]
    $repairTaskDrift = Test-ArthurRepairTaskActionDrift `
        -ExistingAction $existingAction `
        -ExpectedExecute $expectedExecute `
        -ExpectedArguments $expectedArguments `
        -ExpectedWorkingDirectory $expectedWorkingDirectory
    if (-not $existingRepairTask.Principal -or [string]$existingRepairTask.Principal.UserId -ine $interactiveUser) {
        $repairTaskDrift = $true
    }
}

if (-not $existingRepairTask -or $repairTaskDrift) {
    if ($existingRepairTask -and [string]$existingRepairTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $RepairTaskName -ErrorAction Stop
    }
    $task = New-ScheduledTask `
        -Action $canonicalAction `
        -Principal $canonicalPrincipal `
        -Settings $canonicalSettings `
        -Description 'Independent Windows-owned Arthur Codex runtime repair controller. It repairs runtime infrastructure only and has no firmware release authority.'
    Register-ScheduledTask -TaskName $RepairTaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    if ($existingRepairTask) {
        Write-Host "REPAIR_CONTROLLER_TASK_REREGISTERED=PASS task=$RepairTaskName user=$interactiveUser"
    }
    else {
        Write-Host "REPAIR_CONTROLLER_TASK_REGISTERED=PASS task=$RepairTaskName user=$interactiveUser"
    }
}
else {
    Write-Host "REPAIR_CONTROLLER_TASK_REGISTERED=REUSE task=$RepairTaskName user=$interactiveUser state=$($existingRepairTask.State)"
}

if ($Start) {
    $taskNow = Get-ScheduledTask -TaskName $RepairTaskName -ErrorAction Stop
    if ([string]$taskNow.State -ne 'Running') {
        Start-ScheduledTask -TaskName $RepairTaskName -ErrorAction Stop
    }
    Write-Host "REPAIR_CONTROLLER_TASK_TRIGGERED=PASS task=$RepairTaskName mode=$Mode"
}
else {
    Write-Host "REPAIR_CONTROLLER_TASK=PASS task=$RepairTaskName user=$interactiveUser launcher=$launcherPath mode=$Mode"
}

exit 0
