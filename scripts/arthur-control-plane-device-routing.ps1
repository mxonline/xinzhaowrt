Set-StrictMode -Version Latest

function Invoke-ArthurControlPlaneDeviceObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('RELEASE_ONLY','FLASH_AND_VERIFY')][string]$ReleaseMode,
        [Parameter(Mandatory=$true)][scriptblock]$Action
    )

    if ($ReleaseMode -eq 'RELEASE_ONLY') {
        return [pscustomobject][ordered]@{
            skipped = $true
            reason = 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED'
            value = $null
        }
    }

    return [pscustomobject][ordered]@{
        skipped = $false
        reason = 'FLASH_AND_VERIFY_DEVICE_OBSERVATION_REQUIRED'
        value = (& $Action)
    }
}

function Test-ArthurControlPlaneTerminalStatusForActiveExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$TerminalStatus,
        [Parameter(Mandatory=$true)][object]$ResumeState,
        [Parameter(Mandatory=$true)][string]$ExecutionId
    )

    if ([string]$TerminalStatus.status -ne 'PRODUCTION_RELEASED') { return $false }
    if ([string]$ResumeState.execution_id -ne $ExecutionId) { return $false }

    $statusExecutionId = ''
    if ($TerminalStatus.PSObject.Properties['execution_id']) {
        $statusExecutionId = [string]$TerminalStatus.execution_id
    }
    elseif ($TerminalStatus.PSObject.Properties['request_id']) {
        $statusExecutionId = [string]$TerminalStatus.request_id
    }
    if ($statusExecutionId -eq $ExecutionId) { return $true }

    $currentGate = if ($ResumeState.PSObject.Properties['current_gate']) { [string]$ResumeState.current_gate } else { [string]$ResumeState.checkpoint.current }
    $nextAction = if ($ResumeState.PSObject.Properties['next_action']) { [string]$ResumeState.next_action } else { [string]$ResumeState.checkpoint.next_action }
    return ($currentGate -eq 'PRODUCTION_RELEASED' -and $nextAction -eq 'NONE')
}

function Test-ArthurControlPlaneHistoricalSupervisorStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$SupervisorStatus,
        [Parameter(Mandatory=$true)][object]$RuntimeState,
        [Parameter(Mandatory=$true)][object]$ResumeState,
        [Parameter(Mandatory=$true)][string]$ExecutionId
    )

    if ([string]$SupervisorStatus.status -ne 'TERMINAL') { return $false }
    return (Test-ArthurControlPlaneHistoricalRuntimeState -RuntimeState $RuntimeState -ResumeState $ResumeState -ExecutionId $ExecutionId)
}

function Test-ArthurControlPlaneHistoricalRuntimeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$RuntimeState,
        [Parameter(Mandatory=$true)][object]$ResumeState,
        [Parameter(Mandatory=$true)][string]$ExecutionId
    )

    if ([string]$ResumeState.execution_id -ne $ExecutionId) { return $false }

    $currentGate = if ($ResumeState.PSObject.Properties['current_gate']) { [string]$ResumeState.current_gate } else { [string]$ResumeState.checkpoint.current }
    $nextAction = if ($ResumeState.PSObject.Properties['next_action']) { [string]$ResumeState.next_action } else { [string]$ResumeState.checkpoint.next_action }
    if ($currentGate -eq 'PRODUCTION_RELEASED' -and $nextAction -eq 'NONE') { return $false }

    $runtimeExecutionId = ''
    if ($RuntimeState.PSObject.Properties['execution_id']) {
        $runtimeExecutionId = [string]$RuntimeState.execution_id
    }
    elseif ($RuntimeState.PSObject.Properties['observability'] -and $RuntimeState.observability) {
        if ($RuntimeState.observability.PSObject.Properties['active_execution_id']) {
            $runtimeExecutionId = [string]$RuntimeState.observability.active_execution_id
        }
        elseif ($RuntimeState.observability.PSObject.Properties['control_plane_runtime_migration'] -and $RuntimeState.observability.control_plane_runtime_migration.execution_id) {
            $runtimeExecutionId = [string]$RuntimeState.observability.control_plane_runtime_migration.execution_id
        }
    }
    if ($runtimeExecutionId -and $runtimeExecutionId -eq $ExecutionId -and [string]$RuntimeState.terminal_state -eq 'SAFETY_BLOCKED') { return $false }
    if ($runtimeExecutionId -and $runtimeExecutionId -ne $ExecutionId) { return $true }

    $runtimePhase = [string]$RuntimeState.phase
    $runtimeStage = if ($RuntimeState.PSObject.Properties['current_stage']) { [string]$RuntimeState.current_stage } else { $runtimePhase }
    $runtimeTerminal = [string]$RuntimeState.terminal_state
    return ($runtimeTerminal -eq 'PRODUCTION_RELEASED' -or $runtimePhase -ne $currentGate -or $runtimeStage -ne $currentGate)
}

function Test-ArthurControlPlaneRuntimeTerminalForActiveExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$RuntimeState,
        [Parameter(Mandatory=$true)][object]$ResumeState,
        [Parameter(Mandatory=$true)][string]$ExecutionId
    )

    if ([string]$ResumeState.execution_id -ne $ExecutionId) { return $false }
    $currentGate = if ($ResumeState.PSObject.Properties['current_gate']) { [string]$ResumeState.current_gate } else { [string]$ResumeState.checkpoint.current }
    $nextAction = if ($ResumeState.PSObject.Properties['next_action']) { [string]$ResumeState.next_action } else { [string]$ResumeState.checkpoint.next_action }
    if ($currentGate -ne 'PRODUCTION_RELEASED' -or $nextAction -ne 'NONE') { return $false }
    return ([string]$RuntimeState.terminal_state -eq 'PRODUCTION_RELEASED' -or [string]$RuntimeState.phase -eq 'PRODUCTION_RELEASED')
}
