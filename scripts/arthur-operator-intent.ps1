Set-StrictMode -Version Latest

function Get-ArthurIntentMember {
    param([object]$Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ArthurFirmwareExecutionPermission {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$OperatorIntent)

    $intentType = [string](Get-ArthurIntentMember $OperatorIntent 'intent_type')
    $scope = [string](Get-ArthurIntentMember $OperatorIntent 'authorization_scope')
    $authorized = Get-ArthurIntentMember $OperatorIntent 'firmware_execution_authorized'

    if ($authorized -ne $true) {
        return [pscustomobject]@{
            allowed = $false
            reason = 'FIRMWARE_EXECUTION_NOT_AUTHORIZED'
            intent_type = $intentType
            authorization_scope = $scope
        }
    }

    if ($scope -ne 'FIRMWARE_RELEASE' -or $intentType -ne 'EXECUTE_FIRMWARE') {
        return [pscustomobject]@{
            allowed = $false
            reason = 'AUTHORIZATION_SCOPE_MISMATCH'
            intent_type = $intentType
            authorization_scope = $scope
        }
    }

    # A formal Candidate workflow that already owns BUILD is the executor for that
    # Gate. Scheduled Control Plane wakeups must observe it, not start a duplicate
    # Build. The workflow_run state synchronizer adds candidate_release_conclusion
    # when that run completes, which releases this temporary ownership guard.
    $firmwareState = Get-ArthurIntentMember $OperatorIntent 'firmware_state'
    $guardrails = Get-ArthurIntentMember $OperatorIntent 'guardrails'
    $currentStage = [string](Get-ArthurIntentMember $firmwareState 'current_stage')
    $activeRunValue = Get-ArthurIntentMember $firmwareState 'active_run_id'
    $activeRunId = 0L
    if ($null -ne $activeRunValue) { [void][long]::TryParse([string]$activeRunValue,[ref]$activeRunId) }
    $doNotInterrupt = (Get-ArthurIntentMember $guardrails 'do_not_interrupt_active_run') -eq $true
    $completionMarker = Get-ArthurIntentMember $firmwareState 'candidate_release_conclusion'
    if ($currentStage -eq 'BUILD' -and $activeRunId -gt 0 -and $doNotInterrupt -and $null -eq $completionMarker) {
        return [pscustomobject]@{
            allowed = $false
            reason = 'ACTIVE_CANDIDATE_BUILD_OWNS_GATE'
            intent_type = $intentType
            authorization_scope = $scope
            active_run_id = $activeRunId
        }
    }

    return [pscustomobject]@{
        allowed = $true
        reason = 'FIRMWARE_EXECUTION_AUTHORIZED'
        intent_type = $intentType
        authorization_scope = $scope
    }
}

function Read-ArthurOperatorIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'OPERATOR_INTENT_MISSING'
    }
    try {
        $intent = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "OPERATOR_INTENT_INVALID_JSON: $($_.Exception.Message)"
    }

    if ([string](Get-ArthurIntentMember $intent 'project') -ne 'Arthur') {
        throw 'OPERATOR_INTENT_PROJECT_MISMATCH'
    }
    $schema = [string](Get-ArthurIntentMember $intent 'schema_version')
    if ($schema -notin @('1.0','1.1')) {
        throw 'OPERATOR_INTENT_SCHEMA_UNSUPPORTED'
    }
    return $intent
}
