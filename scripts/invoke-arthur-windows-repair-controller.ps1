[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$HeadlessPythonExe,
    [ValidateSet('DiagnosticOnly','WhitelistRepair','FullRecovery')]
    [string]$Mode = 'DiagnosticOnly',
    [string]$SupervisorTaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor',
    [string]$RepairTaskName = 'XinZhaoWrt-Arthur-Repair-Controller'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ArthurRepairBlockedResult {
    param([string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $match = [regex]::Match($Message, 'REPAIR_BLOCKED_[A-Z0-9_]+')
        if ($match.Success) { return $match.Value }
        if ($Message -match 'REPAIR_EXHAUSTED') { return 'REPAIR_EXHAUSTED' }
    }
    return 'REPAIR_BLOCKED_CONTROLLER_ERROR'
}

function Write-ArthurRepairBlockedTerminal {
    param(
        [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$Result,
        [Parameter(Mandatory=$true)][string]$Message
    )

    New-Item -ItemType Directory -Force -Path $StatePath | Out-Null
    $statusPath = Join-Path $StatePath 'repair-status.json'
    $eventsPath = Join-Path $StatePath 'repair-events.jsonl'
    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $status = $null

    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json }
        catch { $status = $null }
    }

    if ($status) {
        $status | Add-Member -NotePropertyName status -NotePropertyValue $Result -Force
        $status | Add-Member -NotePropertyName final_result -NotePropertyValue $Result -Force
        $status | Add-Member -NotePropertyName evidence_timestamp -NotePropertyValue $timestamp -Force
        $status | Add-Member -NotePropertyName terminal_error -NotePropertyValue $Message -Force
    }
    else {
        $status = [pscustomobject][ordered]@{
            schema_version = 1
            status = $Result
            mode = $Mode
            failure_class = $Result
            evidence_timestamp = $timestamp
            repair_attempt_count = 0
            selected_repair_action = $null
            source_sha = $null
            control_runtime_sha = $null
            expected_module_root = [IO.Path]::GetFullPath($ControlRoot)
            actual_module_root = $null
            expected_model = 'gpt-5.6-terra'
            actual_model = $null
            supervisor_pid = $null
            codex_pid = $null
            heartbeat_observations = [ordered]@{ healthy_seconds = 0; heartbeat_advances = 0 }
            runtime_state_identity = $null
            failure_fingerprint = $null
            final_result = $Result
            terminal_error = $Message
        }
    }

    $tmp = "$statusPath.$PID.tmp"
    $json = $status | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $statusPath -Force

    $event = [ordered]@{
        timestamp = $timestamp
        event = 'repair_terminal'
        data = [ordered]@{
            result = $Result
            error = $Message
            mode = $Mode
        }
    }
    Add-Content -LiteralPath $eventsPath -Value ($event | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
}

if ($env:ARTHUR_REPAIR_WRAPPER_IMPORT_ONLY -eq '1') { return }

$statePath = [IO.Path]::GetFullPath($StateDir)
$controlPath = [IO.Path]::GetFullPath($ControlRoot)
$pythonPath = [IO.Path]::GetFullPath($HeadlessPythonExe)
$controllerPath = Join-Path $controlPath 'scripts\arthur-windows-repair-controller.ps1'
if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
    $result = 'REPAIR_BLOCKED_CONTROLLER_ERROR'
    $message = "Arthur Windows repair controller missing: $controllerPath"
    Write-ArthurRepairBlockedTerminal -StatePath $statePath -Result $result -Message $message
    Write-Host "WINDOWS_REPAIR_CLASS=$result"
    throw $message
}

$engine = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { $engine = 'powershell.exe' }
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $controllerPath,
    '-StateDir', $statePath,
    '-ControlRoot', $controlPath,
    '-HeadlessPythonExe', $pythonPath,
    '-Mode', $Mode,
    '-SupervisorTaskName', $SupervisorTaskName,
    '-RepairTaskName', $RepairTaskName
)

$oldPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = @(& $engine @arguments 2>&1)
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $oldPreference
}
foreach ($line in $output) { Write-Host ([string]$line) }
if ($exitCode -eq 0) { exit 0 }

$message = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
if ([string]::IsNullOrWhiteSpace($message)) { $message = "Repair controller exited with code $exitCode" }
$result = Get-ArthurRepairBlockedResult -Message $message
try {
    Write-ArthurRepairBlockedTerminal -StatePath $statePath -Result $result -Message $message
}
catch {
    Write-Warning "REPAIR_BLOCKED_TERMINAL_WRITE_FAILED: $($_.Exception.Message)"
}
Write-Host "WINDOWS_REPAIR_CLASS=$result"
exit $(if ($exitCode -ne 0) { $exitCode } else { 1 })
