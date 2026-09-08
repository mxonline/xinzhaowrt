Set-StrictMode -Version Latest

$stateContractPath = Join-Path $PSScriptRoot 'arthur-state-contract.ps1'
if (-not (Test-Path -LiteralPath $stateContractPath -PathType Leaf)) {
    throw 'ARTHUR_CONSISTENCY_STATE_CONTRACT_MISSING'
}
. $stateContractPath

function Get-ArthurConsistencyGateRecords {
    param([object]$ResumeState)

    $gateMap = Get-ArthurStateMember $ResumeState 'gates'
    if ($null -eq $gateMap) { return @() }

    $records = @()
    foreach ($name in @(Get-ArthurStatePropertyNames $gateMap)) {
        $gate = Get-ArthurStateMember $gateMap $name
        if ($null -ne $gate) { $records += $gate }
    }
    return @($records)
}

function Get-ArthurEvidenceIdFromReference {
    param([object]$Reference)

    $text = ([string]$Reference).Trim()
    if ($text -match '^evidence:(?<id>.+)$') {
        return [string]$Matches['id']
    }
    return ''
}

function Test-ArthurRuntimeStateConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$ResumeState,
        [object[]]$Events = @(),
        [object]$EvidenceIndex = $null
    )

    $conflicts = @()
    $warnings = @()

    $schemaVersion = Get-ArthurStateMember $ResumeState 'schema_version'
    if ($null -eq $schemaVersion -or [int]$schemaVersion -ne 2) {
        $conflicts += 'RESUME_SCHEMA_VERSION_NOT_V2'
    }

    $executionId = ([string](Get-ArthurStateMember $ResumeState 'execution_id')).Trim()
    if ([string]::IsNullOrWhiteSpace($executionId)) {
        $conflicts += 'RESUME_EXECUTION_ID_MISSING'
    }

    $gates = @(Get-ArthurConsistencyGateRecords -ResumeState $ResumeState)
    $gateOrder = @($gates | ForEach-Object { [string](Get-ArthurStateMember $_ 'gate_id') })
    $nextGate = Get-ArthurNextRequiredGate -Gates $gates -GateOrder $gateOrder
    $expectedGate = if ($null -ne $nextGate) { [string](Get-ArthurStateMember $nextGate 'gate_id') } else { '' }
    $currentGate = ([string](Get-ArthurStateMember $ResumeState 'current_gate')).Trim()
    $nextAction = ([string](Get-ArthurStateMember $ResumeState 'next_action')).Trim()

    if (-not [string]::IsNullOrWhiteSpace($expectedGate)) {
        if ($currentGate -ne $expectedGate) {
            $conflicts += "CURRENT_GATE_MISMATCH:${currentGate}:${expectedGate}"
        }
        if ($nextAction -ne $expectedGate) {
            $conflicts += "NEXT_ACTION_MISMATCH:${nextAction}:${expectedGate}"
        }
    }

    $evidenceRecords = @()
    if ($null -ne $EvidenceIndex) {
        $evidenceExecutionId = ([string](Get-ArthurStateMember $EvidenceIndex 'execution_id')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($executionId) -and $evidenceExecutionId -ne $executionId) {
            $conflicts += 'EVIDENCE_EXECUTION_ID_MISMATCH'
        }
        $rawEvidence = Get-ArthurStateMember $EvidenceIndex 'evidence'
        if ($null -ne $rawEvidence) { $evidenceRecords = @($rawEvidence) }
    }

    $evidenceById = @{}
    foreach ($record in $evidenceRecords) {
        $id = ([string](Get-ArthurStateMember $record 'evidence_id')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($id) -and -not $evidenceById.ContainsKey($id)) {
            $evidenceById[$id] = $record
        }
    }

    foreach ($gate in $gates) {
        $gateId = ([string](Get-ArthurStateMember $gate 'gate_id')).Trim()
        $gateStatus = ([string](Get-ArthurStateMember $gate 'status')).Trim()
        foreach ($reference in @((Get-ArthurStateMember $gate 'evidence_refs'))) {
            $evidenceId = Get-ArthurEvidenceIdFromReference -Reference $reference
            if ([string]::IsNullOrWhiteSpace($evidenceId)) { continue }

            if (-not $evidenceById.ContainsKey($evidenceId)) {
                $conflicts += "GATE_EVIDENCE_REF_MISSING:${gateId}:${evidenceId}"
                continue
            }

            $record = $evidenceById[$evidenceId]
            $recordGateId = ([string](Get-ArthurStateMember $record 'gate_id')).Trim()
            if ($recordGateId -ne $gateId) {
                $conflicts += "GATE_EVIDENCE_GATE_MISMATCH:${gateId}:${evidenceId}:${recordGateId}"
            }

            $recordResult = ([string](Get-ArthurStateMember $record 'result')).Trim().ToUpperInvariant()
            if ($gateStatus -eq 'PASS' -and $recordResult -ne 'PASS') {
                $conflicts += "GATE_PASS_EVIDENCE_NOT_PASS:${gateId}:${evidenceId}:${recordResult}"
            }
            elseif ($gateStatus -eq 'RUNNING' -and $recordResult -notin @('RUNNING','PASS')) {
                $conflicts += "GATE_RUNNING_EVIDENCE_INVALID:${gateId}:${evidenceId}:${recordResult}"
            }
        }
    }

    $executionAwareEvents = @()
    foreach ($event in @($Events)) {
        $data = Get-ArthurStateMember $event 'data'
        $eventExecutionId = ([string](Get-ArthurStateMember $data 'execution_id')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($eventExecutionId)) {
            $executionAwareEvents += $event
        }
    }

    if ($executionAwareEvents.Count -gt 0) {
        $latestExecutionEvent = $executionAwareEvents[-1]
        $latestData = Get-ArthurStateMember $latestExecutionEvent 'data'
        $latestExecutionId = ([string](Get-ArthurStateMember $latestData 'execution_id')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($executionId) -and $latestExecutionId -ne $executionId) {
            $conflicts += 'LEDGER_LATEST_EXECUTION_ID_MISMATCH'
        }
    }
    # Migration compatibility: a valid legacy hash-chained ledger may predate
    # execution_id entirely. Absence of execution-aware events must not block or
    # downgrade the current schema-v2 execution; only an explicit conflicting
    # execution-aware event is authoritative enough to fail closed.

    return [pscustomobject][ordered]@{
        consistent = ($conflicts.Count -eq 0)
        execution_id = $executionId
        expected_gate = $expectedGate
        current_gate = $currentGate
        next_action = $nextAction
        evidence_count = $evidenceRecords.Count
        execution_aware_event_count = $executionAwareEvents.Count
        warnings = @($warnings)
        conflicts = @($conflicts)
    }
}
