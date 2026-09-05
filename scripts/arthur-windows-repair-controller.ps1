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

$script:ProtectedPhases = @(
    'ARTIFACT','PRE_FLASH','AUTO_FLASH_SAFETY_GATE','FLASH','WAIT_DEVICE','IDENTIFY',
    'LAN_RUNTIME','DHCP','WAN','DNS','SSH','LUCI','PLUGIN_RUNTIME_22','ARGON_KUCAT_RUNTIME',
    'SYSTEM_HEALTH','RELEASE_GATE','RELEASE','PRODUCTION_RELEASED'
)

function Get-ArthurPropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Read-JsonFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Save-JsonAtomic {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $tmp = "$Path.$PID.tmp"
    $json = $Value | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Add-ArthurRepairEvent {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Event,
        [Parameter(Mandatory=$true)]$Data
    )
    $record = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = $Event
        data = $Data
    }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Add-Content -LiteralPath $Path -Value (($record | ConvertTo-Json -Depth 30 -Compress)) -Encoding UTF8
}

function Get-ArthurRuntimeStateIdentity {
    param([Parameter(Mandatory=$true)]$State)
    return [pscustomobject][ordered]@{
        release_task_id = Get-ArthurPropertyValue $State 'release_task_id'
        repo = Get-ArthurPropertyValue $State 'repo'
        branch = Get-ArthurPropertyValue $State 'branch'
        source_sha = Get-ArthurPropertyValue $State 'source_sha'
        request_id = Get-ArthurPropertyValue $State 'request_id'
        phase = Get-ArthurPropertyValue $State 'phase'
        candidate_sha256 = Get-ArthurPropertyValue $State 'candidate_sha256'
    }
}

function Test-ArthurRuntimeStateIdentity {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)]$Actual)
    $left = $Expected | ConvertTo-Json -Depth 10 -Compress
    $right = $Actual | ConvertTo-Json -Depth 10 -Compress
    return ($left -ceq $right)
}

function Test-ArthurRepairProtectedState {
    param([Parameter(Mandatory=$true)]$State)
    $humanGate = [string](Get-ArthurPropertyValue $State 'human_gate' '')
    if ([string]::IsNullOrWhiteSpace($humanGate)) {
        $humanGate = [string](Get-ArthurPropertyValue $State 'humanGate' '')
    }
    if (-not [string]::IsNullOrWhiteSpace($humanGate)) { return $true }

    $phase = [string](Get-ArthurPropertyValue $State 'phase' '')
    if ([string]::IsNullOrWhiteSpace($phase)) {
        $phase = [string](Get-ArthurPropertyValue $State 'current_stage' '')
    }
    return ($script:ProtectedPhases -contains $phase.ToUpperInvariant())
}

function Get-ArthurScheduledTaskEvidence {
    param([Parameter(Mandatory=$true)][string]$TaskName,[string]$ExpectedLauncher='')
    $result = [ordered]@{
        available = $false
        exists = $false
        state = $null
        user_id = $null
        execute = $null
        arguments = $null
        working_directory = $null
        launcher_drift = $false
    }
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return [pscustomobject]$result
    }
    $result.available = $true
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return [pscustomobject]$result }
    $result.exists = $true
    $result.state = [string]$task.State
    if ($task.Principal) { $result.user_id = [string]$task.Principal.UserId }
    $action = @($task.Actions | Select-Object -First 1)[0]
    if ($action) {
        $result.execute = [string]$action.Execute
        $result.arguments = [string]$action.Arguments
        $result.working_directory = [string]$action.WorkingDirectory
        if (-not [string]::IsNullOrWhiteSpace($ExpectedLauncher)) {
            $result.launcher_drift = ($result.arguments.IndexOf($ExpectedLauncher,[StringComparison]::OrdinalIgnoreCase) -lt 0)
        }
    }
    return [pscustomobject]$result
}

function Get-ArthurProcessEvidence {
    param([Parameter(Mandatory=$true)][string]$StatePath)
    $result = [ordered]@{ supervisor_pid = $null; codex_pid = $null; supervisor_alive = $false; codex_alive = $false }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return [pscustomobject]$result }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        $command = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command -match 'run-supervisor\.py' -and $command.IndexOf($StatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result.supervisor_pid = [int]$process.ProcessId
            $result.supervisor_alive = $true
        }
        if ($command -match 'ai_orchestrator' -and $command -match '\bresume\b' -and $command.IndexOf($StatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result.codex_pid = [int]$process.ProcessId
            $result.codex_alive = $true
        }
    }
    return [pscustomobject]$result
}

function Invoke-ArthurGitText {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& git -C $Root @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ code = $code; output = $output }
}

function Get-ArthurGitEvidence {
    param([Parameter(Mandatory=$true)][string]$Root)
    $result = [ordered]@{ dirty = $true; relation = 'UNKNOWN'; head = $null; origin_main = $null; error = $null }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $result.error = 'GIT_UNAVAILABLE'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'CONTROL_ROOT_MISSING'
        return [pscustomobject]$result
    }
    $status = Invoke-ArthurGitText $Root @('status','--porcelain')
    if ($status.code -ne 0) { $result.error = $status.output; return [pscustomobject]$result }
    $result.dirty = -not [string]::IsNullOrWhiteSpace($status.output)
    $head = Invoke-ArthurGitText $Root @('rev-parse','HEAD')
    if ($head.code -ne 0) { $result.error = $head.output; return [pscustomobject]$result }
    $result.head = $head.output
    $origin = Invoke-ArthurGitText $Root @('rev-parse','origin/main')
    if ($origin.code -ne 0) { $result.error = $origin.output; return [pscustomobject]$result }
    $result.origin_main = $origin.output
    if ($result.head -eq $result.origin_main) {
        $result.relation = 'SAME'
        return [pscustomobject]$result
    }
    $ancestor = Invoke-ArthurGitText $Root @('merge-base','--is-ancestor',$result.head,$result.origin_main)
    if ($ancestor.code -eq 0) { $result.relation = 'BEHIND'; return [pscustomobject]$result }
    $reverse = Invoke-ArthurGitText $Root @('merge-base','--is-ancestor',$result.origin_main,$result.head)
    if ($reverse.code -eq 0) { $result.relation = 'AHEAD'; return [pscustomobject]$result }
    $result.relation = 'DIVERGED'
    return [pscustomobject]$result
}

function Invoke-ArthurRuntimeProbe {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$PythonExe,
        [Parameter(Mandatory=$true)][string]$ExpectedModel
    )
    $probePath = Join-Path $Root 'scripts\arthur-codex-runtime-probe.py'
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        return [pscustomobject]@{ exit_class = 'PROBE_INTERNAL_ERROR'; module_root_ok = $false; model_binding_ok = $false; account_preflight_ok = $false; error = 'PROBE_MISSING' }
    }
    $oldRoot = $env:ARTHUR_CONTROL_PLANE_CODE_ROOT
    $oldModel = $env:HEADLESS_CODEX_MODEL
    try {
        $env:ARTHUR_CONTROL_PLANE_CODE_ROOT = $Root
        $env:HEADLESS_CODEX_MODEL = $ExpectedModel
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& $PythonExe $probePath 2>&1 | Out-String).Trim()
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $oldPreference }
        try { $payload = $raw | ConvertFrom-Json }
        catch {
            return [pscustomobject]@{ exit_class = 'PROBE_INTERNAL_ERROR'; module_root_ok = $false; model_binding_ok = $false; account_preflight_ok = $false; exit_code = $exitCode; error = $raw }
        }
        $actualModule = [string](Get-ArthurPropertyValue $payload 'ai_orchestrator_file' '')
        $actualModel = [string](Get-ArthurPropertyValue $payload 'effective_model' '')
        $payload | Add-Member -NotePropertyName module_root_ok -NotePropertyValue ($actualModule.StartsWith([IO.Path]::GetFullPath($Root),[StringComparison]::OrdinalIgnoreCase)) -Force
        $payload | Add-Member -NotePropertyName model_binding_ok -NotePropertyValue ($actualModel -ceq $ExpectedModel) -Force
        $payload | Add-Member -NotePropertyName exit_code -NotePropertyValue $exitCode -Force
        return $payload
    }
    finally {
        $env:ARTHUR_CONTROL_PLANE_CODE_ROOT = $oldRoot
        $env:HEADLESS_CODEX_MODEL = $oldModel
    }
}

function Get-ArthurRepairFailureClass {
    param([Parameter(Mandatory=$true)]$Evidence)
    if ([bool](Get-ArthurPropertyValue $Evidence 'protected' $false)) { return 'REPAIR_BLOCKED_SAFETY_STATE' }
    $git = Get-ArthurPropertyValue $Evidence 'git'
    if ([bool](Get-ArthurPropertyValue $git 'dirty' $false)) { return 'REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME' }
    $relation = [string](Get-ArthurPropertyValue $git 'relation' 'UNKNOWN')
    if ($relation -eq 'DIVERGED' -or $relation -eq 'AHEAD') { return 'REPAIR_BLOCKED_DIVERGED_CONTROL_RUNTIME' }
    if ($relation -eq 'BEHIND') { return 'CONTROL_RUNTIME_STALE' }
    $task = Get-ArthurPropertyValue $Evidence 'task'
    if ([bool](Get-ArthurPropertyValue $task 'launcher_drift' $false)) { return 'TASK_LAUNCHER_DRIFT' }
    $probe = Get-ArthurPropertyValue $Evidence 'probe'
    $probeClass = [string](Get-ArthurPropertyValue $probe 'exit_class' '')
    if ($probeClass -eq 'MODULE_ROOT_DRIFT' -or -not [bool](Get-ArthurPropertyValue $probe 'module_root_ok' $true)) { return 'MODULE_ROOT_DRIFT' }
    if ($probeClass -eq 'MODEL_BINDING_DRIFT' -or -not [bool](Get-ArthurPropertyValue $probe 'model_binding_ok' $true)) { return 'MODEL_BINDING_DRIFT' }
    $supervisor = Get-ArthurPropertyValue $Evidence 'supervisor'
    if ([string](Get-ArthurPropertyValue $supervisor 'status' '') -eq 'CRASH_LOOP_BLOCKED' -and $probeClass -eq 'PROBE_OK') {
        return 'SUPERVISOR_RETRY_EXHAUSTED'
    }
    return 'UNKNOWN_FAILURE'
}

function Get-ArthurFailureFingerprint {
    param([Parameter(Mandatory=$true)]$Evidence)
    $git = Get-ArthurPropertyValue $Evidence 'git'
    $task = Get-ArthurPropertyValue $Evidence 'task'
    $probe = Get-ArthurPropertyValue $Evidence 'probe'
    $supervisor = Get-ArthurPropertyValue $Evidence 'supervisor'
    $basis = [ordered]@{
        class = Get-ArthurRepairFailureClass $Evidence
        git_relation = Get-ArthurPropertyValue $git 'relation'
        git_dirty = Get-ArthurPropertyValue $git 'dirty'
        task_drift = Get-ArthurPropertyValue $task 'launcher_drift'
        probe_exit = Get-ArthurPropertyValue $probe 'exit_class'
        module_root_ok = Get-ArthurPropertyValue $probe 'module_root_ok'
        model_binding_ok = Get-ArthurPropertyValue $probe 'model_binding_ok'
        supervisor_status = Get-ArthurPropertyValue $supervisor 'status'
    } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($basis)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ArthurRepairEvidence {
    param(
        [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$PythonExe,
        [Parameter(Mandatory=$true)][string]$TaskName
    )
    $runtimePath = Join-Path $StatePath 'runtime-state.json'
    $runtime = Read-JsonFile $runtimePath
    $identity = if ($runtime) { Get-ArthurRuntimeStateIdentity $runtime } else { $null }
    $supervisor = Read-JsonFile (Join-Path $StatePath 'supervisor-status.json')
    if (-not $supervisor) { $supervisor = [pscustomobject]@{ status = 'MISSING' } }
    $expectedModel = 'gpt-5.6-terra'
    $launcher = Join-Path $env:ProgramData 'XinZhaoWrt\PersistentSupervisor\run-arthur-persistent-supervisor.ps1'
    $task = Get-ArthurScheduledTaskEvidence -TaskName $TaskName -ExpectedLauncher $launcher
    $process = Get-ArthurProcessEvidence -StatePath $StatePath
    $probe = Invoke-ArthurRuntimeProbe -Root $Root -PythonExe $PythonExe -ExpectedModel $expectedModel
    return [pscustomobject][ordered]@{
        protected = if ($runtime) { Test-ArthurRepairProtectedState $runtime } else { $true }
        runtime_state = $runtime
        runtime_state_identity = $identity
        git = Get-ArthurGitEvidence $Root
        task = $task
        process = $process
        probe = $probe
        supervisor = $supervisor
        expected_model = $expectedModel
    }
}

function Write-ArthurRepairStatus {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Status)
    Save-JsonAtomic -Path $Path -Value $Status
}

function Invoke-ArthurRepairDiagnostic {
    param(
        [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$PythonExe,
        [Parameter(Mandatory=$true)][string]$TaskName,
        [Parameter(Mandatory=$true)][string]$CurrentMode
    )
    $evidence = Get-ArthurRepairEvidence -StatePath $StatePath -Root $Root -PythonExe $PythonExe -TaskName $TaskName
    $failureClass = Get-ArthurRepairFailureClass $evidence
    $fingerprint = Get-ArthurFailureFingerprint $evidence
    $identity = Get-ArthurPropertyValue $evidence 'runtime_state_identity'
    $git = Get-ArthurPropertyValue $evidence 'git'
    $probe = Get-ArthurPropertyValue $evidence 'probe'
    $process = Get-ArthurPropertyValue $evidence 'process'
    $status = [ordered]@{
        schema_version = 1
        status = 'DIAGNOSING'
        mode = $CurrentMode
        failure_class = $failureClass
        evidence_timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        repair_attempt_count = 0
        selected_repair_action = $null
        source_sha = Get-ArthurPropertyValue $identity 'source_sha'
        control_runtime_sha = Get-ArthurPropertyValue $git 'head'
        expected_module_root = [IO.Path]::GetFullPath($Root)
        actual_module_root = Get-ArthurPropertyValue $probe 'ai_orchestrator_file'
        expected_model = Get-ArthurPropertyValue $evidence 'expected_model'
        actual_model = Get-ArthurPropertyValue $probe 'effective_model'
        supervisor_pid = Get-ArthurPropertyValue $process 'supervisor_pid'
        codex_pid = Get-ArthurPropertyValue $process 'codex_pid'
        runtime_state_identity = $identity
        failure_fingerprint = $fingerprint
        final_result = if ($failureClass -eq 'UNKNOWN_FAILURE') { 'REPAIR_BLOCKED_UNKNOWN_FAILURE' } else { 'DIAGNOSTIC_COMPLETE' }
    }
    $eventsPath = Join-Path $StatePath 'repair-events.jsonl'
    Add-ArthurRepairEvent -Path $eventsPath -Event 'repair_cycle_started' -Data ([ordered]@{ mode = $CurrentMode; failure_fingerprint = $fingerprint })
    Write-ArthurRepairStatus -Path (Join-Path $StatePath 'repair-status.json') -Status $status
    Add-ArthurRepairEvent -Path $eventsPath -Event 'diagnostic_terminal' -Data ([ordered]@{ failure_class = $failureClass; final_result = $status.final_result })
    Write-Host "WINDOWS_REPAIR_DIAGNOSIS=PASS"
    Write-Host "WINDOWS_REPAIR_CLASS=$failureClass"
    return [pscustomobject]$status
}

if ($env:ARTHUR_REPAIR_CONTROLLER_IMPORT_ONLY -eq '1') {
    return
}

$statePath = [IO.Path]::GetFullPath($StateDir)
$controlPath = [IO.Path]::GetFullPath($ControlRoot)
$pythonPath = [IO.Path]::GetFullPath($HeadlessPythonExe)
New-Item -ItemType Directory -Force -Path $statePath | Out-Null

$lockPath = Join-Path $statePath 'repair-controller.lock'
$lock = $null
try {
    try {
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    catch [IO.IOException] {
        Write-Host 'REPAIR_CONTROLLER_ALREADY_RUNNING=PASS'
        exit 0
    }

    if ($Mode -ne 'DiagnosticOnly') {
        $blocked = [ordered]@{
            schema_version = 1
            status = 'DIAGNOSING'
            mode = $Mode
            failure_class = 'UNKNOWN_FAILURE'
            evidence_timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            repair_attempt_count = 0
            selected_repair_action = $null
            source_sha = $null
            control_runtime_sha = $null
            expected_module_root = $controlPath
            actual_module_root = $null
            expected_model = 'gpt-5.6-terra'
            actual_model = $null
            supervisor_pid = $null
            codex_pid = $null
            runtime_state_identity = $null
            failure_fingerprint = $null
            final_result = 'REPAIR_BLOCKED_MODE_NOT_IMPLEMENTED'
        }
        Write-ArthurRepairStatus -Path (Join-Path $statePath 'repair-status.json') -Status $blocked
        Write-Host 'WINDOWS_REPAIR_CLASS=UNKNOWN_FAILURE'
        exit 2
    }

    $null = Invoke-ArthurRepairDiagnostic -StatePath $statePath -Root $controlPath -PythonExe $pythonPath -TaskName $SupervisorTaskName -CurrentMode $Mode
    exit 0
}
finally {
    if ($lock) { $lock.Dispose() }
}
