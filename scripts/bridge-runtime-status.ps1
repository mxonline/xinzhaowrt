$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

Write-Host "BRIDGE_DIAG_MACHINE=$env:COMPUTERNAME"
Write-Host "BRIDGE_DIAG_RUNNER_USER=$env:USERDOMAIN\$env:USERNAME"

$repo = 'C:\Users\chenz\xinzhaowrt'
$orchestrator = Join-Path $repo 'ai_orchestrator'
$state = Join-Path $repo '.ai-orchestrator'
$codex = 'C:\Users\chenz\AppData\Roaming\Python\Python314\site-packages\codex_cli_bin\bin\codex.exe'

Write-Host "BRIDGE_ORIGINAL_REPO_EXISTS=$([bool](Test-Path $repo))"
Write-Host "BRIDGE_ORCHESTRATOR_EXISTS=$([bool](Test-Path $orchestrator))"
Write-Host "BRIDGE_STATE_DIR_EXISTS=$([bool](Test-Path $state))"
Write-Host "BRIDGE_CODEX_EXE_EXISTS=$([bool](Test-Path $codex))"

if (Test-Path $orchestrator) {
    foreach ($name in @('runtime.py','supervisor.py','controller.py','bridge.py','policy.py')) {
        Write-Host ("BRIDGE_FILE_{0}={1}" -f $name.ToUpperInvariant().Replace('.','_'), [bool](Test-Path (Join-Path $orchestrator $name)))
    }
}

if (Test-Path $state) {
    $names = @(Get-ChildItem -Path $state -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Write-Host "BRIDGE_STATE_FILES=$($names -join ',')"
}

$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -match '(?i)gpt|codex|bridge|orchestrator|xinzhao'
})
if ($tasks.Count -eq 0) {
    Write-Host 'BRIDGE_TASKS=NONE'
} else {
    foreach ($task in $tasks) {
        $execute = @($task.Actions | ForEach-Object { $_.Execute }) -join ';'
        Write-Host "BRIDGE_TASK name=$($task.TaskName) state=$($task.State) user=$($task.Principal.UserId) execute=$execute"
    }
}

$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and ($_.ExecutablePath -like 'C:\Users\chenz\*' -or $_.Name -match '(?i)codex|python')
})
if ($processes.Count -eq 0) {
    Write-Host 'BRIDGE_PROCESSES=NONE'
} else {
    foreach ($p in $processes) {
        Write-Host "BRIDGE_PROCESS pid=$($p.ProcessId) name=$($p.Name) path=$($p.ExecutablePath)"
    }
}

Write-Host 'BRIDGE_RUNTIME_DIAG=PASS'
