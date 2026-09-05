[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [int]$EventTail = 20,
    [switch]$SkipExternal,
    [switch]$AllowRepositoryHeadDriftForReconciliation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$intentPath = Join-Path $root 'production\operator-intent.json'
$resumePath = Join-Path $root 'production\resume-state.json'
$ledgerPath = Join-Path $root 'production\firmware-events.jsonl'
$ledgerLibPath = Join-Path $root 'scripts\arthur-firmware-event-ledger.ps1'
$gitShaHelperPath = Join-Path $root 'scripts\arthur-git-sha.ps1'

if (-not (Test-Path -LiteralPath $ledgerLibPath -PathType Leaf)) { throw 'RESUME_GATE_LEDGER_HELPER_MISSING' }
if (-not (Test-Path -LiteralPath $gitShaHelperPath -PathType Leaf)) { throw 'RESUME_GATE_GIT_SHA_HELPER_MISSING' }
. $ledgerLibPath
. $gitShaHelperPath

function Read-JsonFile {
    param([string]$Path,[string]$MissingCode)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $MissingCode }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { throw "RESUME_GATE_INVALID_JSON: path=$Path error=$($_.Exception.Message)" }
}

$intent = Read-JsonFile -Path $intentPath -MissingCode 'RESUME_GATE_OPERATOR_INTENT_MISSING'
$resume = Read-JsonFile -Path $resumePath -MissingCode 'RESUME_GATE_STATE_MISSING'
[void](Test-ArthurFirmwareEventLedger -Path $ledgerPath)
$events = @(Get-ArthurFirmwareEvents -Path $ledgerPath)
$tail = @($events | Select-Object -Last ([Math]::Max(1,$EventTail)))

Push-Location $root
try {
    $effectiveHeadRaw = (& git log -1 --format=%H -- . ':(exclude)production/resume-state.json' ':(exclude)production/firmware-events.jsonl' | Out-String)
}
finally { Pop-Location }
$effectiveHead = ConvertTo-ArthurCanonicalGitSha $effectiveHeadRaw

$github = [ordered]@{ checked = $false; status = 'SKIPPED'; runs = @() }
if (-not $SkipExternal) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $github.status = 'GH_UNAVAILABLE'
    }
    else {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& gh run list --repo $Repository --limit 10 --json databaseId,status,conclusion,headSha,headBranch,workflowName,createdAt 2>&1 | Out-String).Trim()
            $ghCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
        if ($ghCode -ne 0) { $github.status = "GH_QUERY_FAILED: $raw" }
        else {
            try {
                $github.runs = @($raw | ConvertFrom-Json)
                $github.checked = $true
                $github.status = 'PASS'
            }
            catch { $github.status = "GH_INVALID_JSON: $($_.Exception.Message)" }
        }
    }
}

$conflicts = @()
$reconciliationWarnings = @()
if ([string]$intent.project -ne 'Arthur') { $conflicts += 'OPERATOR_INTENT_PROJECT_MISMATCH' }
if ([string]$resume.status -ne 'RESUME_SAFE') { $conflicts += "RESUME_STATUS_$([string]$resume.status)" }
if ($resume.instruction_allowed -ne $true) { $conflicts += 'RESUME_INSTRUCTION_NOT_ALLOWED' }
if ([string]::IsNullOrWhiteSpace($effectiveHead)) { $conflicts += 'EFFECTIVE_GITHUB_HEAD_INVALID' }
if (-not $SkipExternal -and -not $github.checked) { $conflicts += "GITHUB_EVIDENCE_UNAVAILABLE:$($github.status)" }

$resumeHead = ConvertTo-ArthurCanonicalGitSha $resume.repository_head
if ([string]::IsNullOrWhiteSpace($resumeHead)) {
    $conflicts += 'RESUME_REPOSITORY_HEAD_INVALID'
}
$headDrift = (
    -not [string]::IsNullOrWhiteSpace($effectiveHead) -and
    -not [string]::IsNullOrWhiteSpace($resumeHead) -and
    -not [string]::Equals($effectiveHead,$resumeHead,[StringComparison]::OrdinalIgnoreCase)
)
if ($headDrift) {
    $headMessage = "REPOSITORY_HEAD_MISMATCH:resume=${resumeHead}:effective=${effectiveHead}"
    if ($AllowRepositoryHeadDriftForReconciliation) { $reconciliationWarnings += $headMessage }
    else { $conflicts += $headMessage }
}

$intentStage = if ($intent.firmware_state -and $intent.firmware_state.current_stage) { [string]$intent.firmware_state.current_stage } else { '' }
$resumeStage = if ($resume.checkpoint -and $resume.checkpoint.current) { [string]$resume.checkpoint.current } else { '' }
$resumeNext = if ($resume.next_action) { [string]$resume.next_action } else { '' }
if ($intentStage -and $resumeStage -and $intentStage -ne $resumeStage -and $intentStage -ne $resumeNext) {
    $conflicts += "OPERATOR_RESUME_STAGE_MISMATCH:${intentStage}:${resumeStage}:${resumeNext}"
}

$lastEvent = if ($events.Count -gt 0) { $events[-1] } else { $null }
$executionAuthorized = ([string]$intent.intent_type -eq 'EXECUTE_FIRMWARE' -and [string]$intent.authorization_scope -eq 'FIRMWARE_RELEASE' -and $intent.firmware_execution_authorized -eq $true)
$gateSafe = ($conflicts.Count -eq 0)
$reconciliationRequired = ($reconciliationWarnings.Count -gt 0)
$executionAllowed = ($gateSafe -and -not $reconciliationRequired -and $executionAuthorized -and $resume.instruction_allowed -eq $true)
$gateStatus = if (-not $gateSafe) { 'RESUME_GATE_CONFLICT' } elseif ($reconciliationRequired) { 'RESUME_GATE_RECONCILIATION_ALLOWED' } else { 'RESUME_GATE_SAFE' }

$result = [ordered]@{
    schema_version = 1
    generated_at = [DateTimeOffset]::UtcNow.ToString('o')
    gate = $gateStatus
    execution_allowed = $executionAllowed
    reconciliation_required = $reconciliationRequired
    operator_intent = [ordered]@{
        intent_type = [string]$intent.intent_type
        authorization_scope = [string]$intent.authorization_scope
        firmware_execution_authorized = [bool]$intent.firmware_execution_authorized
        current_stage = $intentStage
        next_stage = if ($intent.firmware_state) { [string]$intent.firmware_state.next_stage } else { '' }
    }
    resume_state = [ordered]@{
        status = [string]$resume.status
        instruction_allowed = [bool]$resume.instruction_allowed
        repository_head = $resumeHead
        current_stage = $resumeStage
        next_action = $resumeNext
        evidence_timestamp = if ($resume.PSObject.Properties['evidence_timestamp']) { [string]$resume.evidence_timestamp } else { '' }
        real_device = $resume.real_device
        verified = $resume.verified
        pending = @($resume.pending)
        conflicts = @($resume.conflicts)
    }
    effective_repository_head = $effectiveHead
    repository_head_match = (-not $headDrift)
    event_ledger = [ordered]@{
        valid = $true
        total_events = $events.Count
        last_seq = if ($lastEvent) { [long]$lastEvent.seq } else { 0 }
        last_time = if ($lastEvent) { [string]$lastEvent.time } else { '' }
        recent = $tail
    }
    github = $github
    reconciliation_warnings = $reconciliationWarnings
    conflicts = $conflicts
}

$result | ConvertTo-Json -Depth 40
if (-not $gateSafe) { exit 2 }
exit 0
