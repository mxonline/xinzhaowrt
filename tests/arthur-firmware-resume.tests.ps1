$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LedgerPath = Join-Path $Root 'production\firmware-events.jsonl'
$LedgerLibPath = Join-Path $Root 'scripts\arthur-firmware-event-ledger.ps1'
$HistoryGuardPath = Join-Path $Root 'scripts\check-firmware-event-ledger-history.ps1'
$ResumePath = Join-Path $Root 'scripts\arthur-firmware-resume.ps1'
$GitShaHelperPath = Join-Path $Root 'scripts\arthur-git-sha.ps1'
$RulesPath = Join-Path $Root 'production\GPT-FIRMWARE-EXECUTION-RULES.md'
$AgentsPath = Join-Path $Root 'AGENTS.md'
$ControlPlaneGatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

function Assert-Throws {
    param([scriptblock]$Action,[string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "TEST_FAIL: $Message" }
}

Assert-True (Test-Path $LedgerPath) 'append-only firmware event ledger must exist'
Assert-True (Test-Path $LedgerLibPath) 'firmware event ledger helper must exist'
Assert-True (Test-Path $HistoryGuardPath) 'git history guard must enforce append-only ledger changes'
Assert-True (Test-Path $ResumePath) 'unified firmware resume gate must exist'
Assert-True (Test-Path $GitShaHelperPath) 'canonical Git SHA helper must exist'
Assert-True (Test-Path $ControlPlaneGatePath) 'control-plane entry gate must exist'

. $LedgerLibPath
. $GitShaHelperPath

# Windows self-hosted evidence showed a valid 40-hex durable repository_head being
# classified as RESUME_REPOSITORY_HEAD_INVALID. Canonicalize before validation so
# whitespace/serialization artifacts cannot turn a valid SHA into a hard conflict.
$knownSha = 'db57876a2481c351fc1e1bb9dcc7e44247aee1dc'
Assert-Equal (ConvertTo-ArthurCanonicalGitSha $knownSha) $knownSha 'valid lowercase SHA must round-trip'
Assert-Equal (ConvertTo-ArthurCanonicalGitSha ('  ' + $knownSha.ToUpperInvariant() + "`r`n")) $knownSha 'valid SHA must normalize case and surrounding whitespace'
Assert-Equal (ConvertTo-ArthurCanonicalGitSha 'not-a-sha') '' 'invalid SHA must fail closed'
Assert-Equal (ConvertTo-ArthurCanonicalGitSha '') '' 'empty SHA must fail closed'

$temp = Join-Path ([IO.Path]::GetTempPath()) ("arthur-firmware-events-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
try {
    [IO.File]::WriteAllText($temp, '', [Text.UTF8Encoding]::new($false))
    $first = Add-ArthurFirmwareEvent -Path $temp -Event 'TEST_STARTED' -Stage 'ADH_MANAGEMENT' -Source 'TEST' -Timestamp '2026-09-05T18:50:00+08:00' -Data @{ marker = 'a' }
    $second = Add-ArthurFirmwareEvent -Path $temp -Event 'TEST_VERIFIED' -Stage 'ADH_MANAGEMENT' -Source 'TEST' -Timestamp '2026-09-05T18:51:00+08:00' -Data @{ marker = 'b' }

    $events = @(Get-ArthurFirmwareEvents -Path $temp)
    Assert-Equal $events.Count 2 'ledger must retain both events rather than overwrite the first'
    Assert-Equal $events[0].seq 1 'first event sequence must be one'
    Assert-Equal $events[1].seq 2 'second event sequence must increment monotonically'
    Assert-Equal $events[1].prev_hash $events[0].event_hash 'second event must chain to first event hash'
    Assert-True ([bool](Test-ArthurFirmwareEventLedger -Path $temp)) 'untampered ledger must validate'

    $raw = Get-Content -LiteralPath $temp
    $tampered = ($raw[0] | ConvertFrom-Json)
    $tampered.event = 'TAMPERED'
    $raw[0] = ($tampered | ConvertTo-Json -Compress -Depth 20)
    [IO.File]::WriteAllLines($temp, $raw, [Text.UTF8Encoding]::new($false))
    Assert-Throws { Test-ArthurFirmwareEventLedger -Path $temp | Out-Null } 'tampered historical event must fail hash-chain validation'
}
finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

$ledgerLines = @(Get-Content -LiteralPath $LedgerPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-True ($ledgerLines.Count -ge 1) 'repository ledger must contain a bootstrap event'
foreach ($line in $ledgerLines) { $null = $line | ConvertFrom-Json }
Assert-True ([bool](Test-ArthurFirmwareEventLedger -Path $LedgerPath)) 'repository ledger must have a valid hash chain'
$bootstrap = $ledgerLines[0] | ConvertFrom-Json
Assert-Equal ([string]$bootstrap.stage) '' 'ledger bootstrap must not invent a firmware stage before historical capture existed'

$historyGuard = Get-Content -Raw $HistoryGuardPath
Assert-Contains $historyGuard 'FIRMWARE_EVENT_HISTORY_APPEND_ONLY=PASS' 'history guard must emit explicit append-only success'
Assert-Contains $historyGuard 'FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED' 'history guard must fail closed when historical bytes change'
Assert-Contains $historyGuard 'git show' 'history guard must compare the ledger against the base revision'

$resume = Get-Content -Raw $ResumePath
Assert-Contains $resume 'production\operator-intent.json' 'resume gate must read durable operator intent'
Assert-Contains $resume 'production\resume-state.json' 'resume gate must read canonical resume snapshot'
Assert-Contains $resume 'production\firmware-events.jsonl' 'resume gate must read immutable event history'
Assert-Contains $resume 'arthur-git-sha.ps1' 'resume gate must load canonical Git SHA normalization'
Assert-Contains $resume 'ConvertTo-ArthurCanonicalGitSha' 'resume gate must normalize both effective and durable source identities before comparison'
Assert-Contains $resume 'git log -1' 'resume gate must inspect effective repository HEAD'
Assert-Contains $resume 'gh run list' 'resume gate must inspect current GitHub workflow evidence when external checks are enabled'
Assert-Contains $resume 'REPOSITORY_HEAD_MISMATCH' 'resume gate must detect stale snapshot source identity'
Assert-Contains $resume 'GITHUB_EVIDENCE_UNAVAILABLE' 'resume gate must fail closed when required GitHub evidence cannot be read'
Assert-Contains $resume 'AllowRepositoryHeadDriftForReconciliation' 'only the reconciler may tolerate source-head drift long enough to repair the snapshot'
Assert-Contains $resume 'RESUME_GATE_SAFE' 'resume gate must emit an explicit safe result'
Assert-Contains $resume 'RESUME_GATE_CONFLICT' 'resume gate must fail closed on conflicting state'

$controlPlaneGate = Get-Content -Raw $ControlPlaneGatePath
Assert-Contains $controlPlaneGate 'arthur-firmware-resume.ps1' 'control-plane entry must run the unified resume gate'
Assert-Contains $controlPlaneGate 'AllowRepositoryHeadDriftForReconciliation' 'control-plane entry may tolerate source-head drift only for machine reconciliation'
Assert-Contains $controlPlaneGate 'UNIFIED_RESUME_GATE=PASS' 'control-plane entry must prove resume gate completion before mutation'

$rules = Get-Content -Raw $RulesPath
Assert-Contains $rules 'firmware-events.jsonl' 'GPT rules must require reading the event ledger'
Assert-Contains $rules 'ISO 8601' 'GPT rules must forbid relative-time state as machine truth'
Assert-Contains $rules 'today' 'GPT rules must explicitly demote today/yesterday-style relative time'
Assert-Contains $rules 'event ledger' 'GPT rules must describe the historical event source'

$agents = Get-Content -Raw $AgentsPath
Assert-Contains $agents 'production/firmware-events.jsonl' 'Codex startup must read firmware event history before executable action selection'
Assert-Contains $agents 'scripts/arthur-firmware-resume.ps1' 'Codex must use the unified resume gate'

$controlPlane = Get-Content -Raw $ControlPlanePath
Assert-Contains $controlPlane 'arthur-firmware-event-ledger.ps1' 'Control Plane must load event-ledger helper'
Assert-Contains $controlPlane 'Add-ArthurFirmwareEvent' 'Control Plane must append state-transition evidence'
Assert-Contains $controlPlane "':(exclude)production/firmware-events.jsonl'" 'state-only event commits must not become effective firmware source HEAD'
Assert-Contains $controlPlane "git add -- 'production/resume-state.json' 'production/firmware-events.jsonl'" 'resume snapshot and event history must publish atomically in one state commit'

Write-Host 'ARTHUR_FIRMWARE_EVENT_LEDGER_CONTRACT=PASS'
Write-Host 'ARTHUR_UNIFIED_RESUME_GATE_CONTRACT=PASS'
Write-Host 'ARTHUR_GIT_SHA_CANONICALIZATION_CONTRACT=PASS'
