$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$WakeupPath = Join-Path $Root '.github\workflows\production-agent-deploy.yml'
$RecoveryRuntimePath = Join-Path $Root 'ai_orchestrator\recovery_runtime.py'
$SupervisorPath = Join-Path $Root 'ai_orchestrator\supervisor.py'
$WindowsProcessPath = Join-Path $Root 'ai_orchestrator\windows_process.py'
$ShimPath = Join-Path $Root 'scripts\run-supervisor.py'
$PersistentSupervisorTaskPath = Join-Path $Root 'scripts\ensure-arthur-persistent-supervisor.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}

Assert-True (Test-Path $PersistentSupervisorTaskPath) 'persistent Arthur supervisor Scheduled Task installer must exist'

$controlPlane = Get-Content -Raw $ControlPlanePath
$wakeup = Get-Content -Raw $WakeupPath
$recoveryRuntime = Get-Content -Raw $RecoveryRuntimePath
$supervisor = Get-Content -Raw $SupervisorPath
$windowsProcess = Get-Content -Raw $WindowsProcessPath
$shim = Get-Content -Raw $ShimPath
$persistentSupervisorTask = Get-Content -Raw $PersistentSupervisorTaskPath

# The five-minute runner wakeup must no longer own a single ProductionRuntime turn.
Assert-Contains $controlPlane 'run-supervisor.py' 'Control Plane must delegate runtime lifecycle to the existing recovery supervisor shim'
Assert-Contains $controlPlane '--once' 'Control Plane must use one idempotent supervisor health/recovery tick per runner wakeup'
Assert-NotContains $controlPlane '--max-turns 1' 'Control Plane must not limit ProductionRuntime to one turn per GitHub schedule tick'
Assert-NotContains $controlPlane 'HEADLESS_RUNTIME_NO_PROGRESS' 'Control Plane must not require asynchronous ProductionRuntime progress inside the same wakeup job'
Assert-Contains $controlPlane 'RECOVERY_SUPERVISOR_WAKEUP=PASS' 'Control Plane must emit explicit supervisor handoff evidence'

# A failed supervisor tick must expose enough persisted evidence in the same Actions log to diagnose the first cause.
Assert-Contains $shim 'RECOVERY_SUPERVISOR_STATUS=' 'Supervisor shim must print supervisor-status.json evidence before returning a failed wakeup'
Assert-Contains $shim 'RECOVERY_SUPERVISOR_LOG_TAIL_BEGIN' 'Supervisor shim must print the persisted supervisor log tail before returning a failed wakeup'
Assert-Contains $shim 'RECOVERY_SUPERVISOR_LOG_TAIL_END' 'Supervisor shim must delimit the persisted supervisor log tail in Actions'

# The detached runtime must use the pinned persistent Python/Codex environment prepared by the runner workflow.
Assert-Contains $wakeup 'HEADLESS_PYTHON_EXE' 'runner wakeup must retain the verified persistent headless interpreter evidence'
Assert-Contains $windowsProcess 'HEADLESS_PYTHON_EXE' 'supervisor child interpreter selection must reuse the verified persistent headless Python when available'

# GitHub Actions kills descendant pythonw processes during job cleanup. The durable
# supervisor must therefore be owned by Windows Task Scheduler in the interactive
# desktop user context, while the five-minute wakeup keeps only the idempotent
# --once health tick. This reuses the repository's existing Scheduled Task recovery
# pattern instead of inventing another daemon/controller.
Assert-Contains $wakeup 'ensure-arthur-persistent-supervisor.ps1' 'runner wakeup must install/start the persistent supervisor through the Scheduled Task helper'
Assert-Contains $wakeup 'PERSISTENT_SUPERVISOR_TASK=PASS' 'runner wakeup must require explicit persistent supervisor handoff evidence'
Assert-Contains $persistentSupervisorTask 'XinZhaoWrt-Arthur-Persistent-Supervisor' 'persistent supervisor task name must be stable and idempotent'
Assert-Contains $persistentSupervisorTask 'New-ScheduledTaskPrincipal' 'persistent supervisor must use the existing Windows Scheduled Task pattern'
Assert-Contains $persistentSupervisorTask 'LogonType Interactive' 'persistent supervisor must run in the active desktop user context so existing Codex credentials remain available'
Assert-Contains $persistentSupervisorTask 'Start-ScheduledTask' 'persistent supervisor task must be started immediately after registration'
Assert-Contains $persistentSupervisorTask '--interval 30' 'persistent supervisor must run continuously at the existing 30-second watchdog cadence'
Assert-Contains $persistentSupervisorTask 'HEADLESS_PYTHON_EXE' 'persistent supervisor launcher must bind the verified managed Python/Codex interpreter'
Assert-Contains $persistentSupervisorTask 'ARTHUR_CONTROL_PLANE_CODE_ROOT' 'persistent supervisor launcher must use the clean current-main control-code checkout'
Assert-NotContains $persistentSupervisorTask '--once' 'persistent Scheduled Task must not inherit the one-shot Actions wakeup mode'

# Control code must stay up to date even while the task workspace is intentionally dirty.
Assert-Contains $wakeup 'control-runtime' 'runner wakeup must maintain a separate clean control-code checkout'
Assert-Contains $wakeup 'ARTHUR_CONTROL_PLANE_CODE_ROOT' 'runner wakeup must export the clean control-code root separately from the task workspace'
Assert-Contains $wakeup 'CONTROL_PLANE_CODE=PASS' 'runner wakeup must emit the exact clean control-code SHA used for each wakeup'
Assert-Contains $wakeup '$env:ARTHUR_CONTROL_PLANE_CODE_ROOT' 'the scoped gate must execute from the clean control-code root'
Assert-Contains $wakeup 'CONTROL_PLANE_WORKSPACE_DIRTY=PRESERVED' 'dirty task changes must still be preserved without blocking control-code updates'
Assert-Contains $wakeup 'PYTHONDONTWRITEBYTECODE' 'clean Control Plane code must disable Python bytecode writes that would dirty the mirror'
Assert-Contains $wakeup '__pycache__' 'wakeup may remove only known generated Python cache directories from clean control code'
Assert-Contains $wakeup 'CONTROL_PLANE_CODE_DIRTY_FILES_BEGIN' 'unexpected control-code dirtiness must print the exact file list before fail-closed'
Assert-Contains $wakeup 'CONTROL_PLANE_CODE_DIRTY_FILES_END' 'unexpected control-code dirtiness output must be delimited'
Assert-NotContains $wakeup 'git clean' 'clean Control Plane recovery must not use broad git clean'
Assert-NotContains $wakeup 'reset --hard' 'clean Control Plane recovery must not use destructive reset'
Assert-Contains $controlPlane '$codeRoot' 'Control Plane must distinguish clean control code from the mutable task workspace'
Assert-Contains $controlPlane "Join-Path `$codeRoot 'scripts\arthur-resume-state.ps1'" 'resume-state helper must come from clean control code'
Assert-Contains $controlPlane "Join-Path `$codeRoot 'scripts\run-supervisor.py'" 'recovery supervisor shim must come from clean control code'

# Reuse the already-tested recovery architecture; do not invent another controller.
Assert-Contains $shim 'ai_orchestrator.recovery_runtime' 'production supervisor shim must use RecoveryRuntimeSupervisor'
Assert-Contains $recoveryRuntime 'class RecoveryRuntimeSupervisor' 'durable recovery supervisor must remain the runtime owner'
Assert-Contains $recoveryRuntime 'resume_persisted_handoff' 'recovery supervisor must resume the same persisted release task after runtime loss'
Assert-Contains $supervisor '"resume"' 'supervisor child must run the continuous ai_orchestrator resume entrypoint'
Assert-NotContains $supervisor '"--max-turns"' 'supervisor child must not be artificially bounded to a single turn'

Write-Host 'ARTHUR_RECOVERY_SUPERVISOR_WIRING_CONTRACT=PASS'
Write-Host 'ARTHUR_RECOVERY_SUPERVISOR_DIAGNOSTICS_CONTRACT=PASS'
Write-Host 'ARTHUR_PERSISTENT_SUPERVISOR_TASK_CONTRACT=PASS'
Write-Host 'ARTHUR_CONTROL_RUNTIME_PYTHON_CACHE_CONTRACT=PASS'
Write-Host 'ARTHUR_CONTROL_CODE_TASK_WORKSPACE_SEPARATION_CONTRACT=PASS'
