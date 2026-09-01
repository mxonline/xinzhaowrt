$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

Write-Host "BRIDGE_DIAG_MACHINE=$env:COMPUTERNAME"
Write-Host "BRIDGE_DIAG_RUNNER_USER=$env:USERDOMAIN\$env:USERNAME"

$repo = 'C:\Users\chenz\xinzhaowrt'
$orchestrator = Join-Path $repo 'ai_orchestrator'
$state = Join-Path $repo '.ai-orchestrator'
$codex = 'C:\Users\chenz\AppData\Roaming\Python\Python314\site-packages\codex_cli_bin\bin\codex.exe'

function Safe-TestPath([string]$Path) {
    try { return [bool](Test-Path $Path -ErrorAction Stop) }
    catch {
        Write-Host "BRIDGE_PATH_ACCESS_DENIED=$Path"
        return $false
    }
}

Write-Host "BRIDGE_ORIGINAL_REPO_EXISTS=$(Safe-TestPath $repo)"
Write-Host "BRIDGE_ORCHESTRATOR_EXISTS=$(Safe-TestPath $orchestrator)"
Write-Host "BRIDGE_STATE_DIR_EXISTS=$(Safe-TestPath $state)"
Write-Host "BRIDGE_CODEX_EXE_EXISTS=$(Safe-TestPath $codex)"

if (Safe-TestPath $orchestrator) {
    foreach ($name in @('runtime.py','supervisor.py','controller.py','bridge.py','policy.py')) {
        Write-Host ("BRIDGE_FILE_{0}={1}" -f $name.ToUpperInvariant().Replace('.','_'), (Safe-TestPath (Join-Path $orchestrator $name)))
    }
}

if (Safe-TestPath $state) {
    $names = @(Get-ChildItem -Path $state -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Write-Host "BRIDGE_STATE_FILES=$($names -join ',')"
}

$allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
$tasks = @($allTasks | Where-Object {
    $execute = @($_.Actions | ForEach-Object { $_.Execute }) -join ';'
    $_.TaskName -match '(?i)gpt|codex|bridge|orchestrator|xinzhao' -or $execute -like 'C:\Users\chenz\*'
})
if ($tasks.Count -eq 0) {
    Write-Host 'BRIDGE_TASKS=NONE'
} else {
    foreach ($task in $tasks) {
        $execute = @($task.Actions | ForEach-Object { $_.Execute }) -join ';'
        $workdir = @($task.Actions | ForEach-Object { $_.WorkingDirectory }) -join ';'
        Write-Host "BRIDGE_TASK name=$($task.TaskName) state=$($task.State) user=$($task.Principal.UserId) execute=$execute workdir=$workdir"
    }
}

try {
    $sessions = (& quser.exe 2>&1 | Out-String).Trim()
    if ($sessions) { Write-Host "BRIDGE_USER_SESSIONS=$($sessions -replace "`r?`n", ' | ')" }
} catch {
    Write-Host "BRIDGE_USER_SESSIONS=UNAVAILABLE"
}

$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and ($_.ExecutablePath -like 'C:\Users\chenz\*' -or $_.Name -match '(?i)codex|python')
})
if ($processes.Count -eq 0) {
    Write-Host 'BRIDGE_PROCESSES=NONE'
} else {
    foreach ($p in $processes) {
        Write-Host "BRIDGE_PROCESS pid=$($p.ProcessId) ppid=$($p.ParentProcessId) name=$($p.Name) path=$($p.ExecutablePath)"
    }
}

Write-Host 'BRIDGE_RUNTIME_DIAG=PASS'
