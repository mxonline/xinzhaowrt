$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EvidencePath = Join-Path $Root 'scripts\arthur-evidence-index.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

function Assert-Throws {
    param([scriptblock]$Action,[string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "TEST_FAIL: $Message" }
}

Assert-True (Test-Path -LiteralPath $EvidencePath -PathType Leaf) 'Arthur evidence-index helper must exist'
. $EvidencePath

$temp = Join-Path ([IO.Path]::GetTempPath()) ("arthur-evidence-{0}" -f ([Guid]::NewGuid().ToString('N')))
$executionId = 'arthur-adh-cn-aaaaaaa-20260908'
try {
    $indexPath = Get-ArthurEvidenceIndexPath -Root $temp -ExecutionId $executionId
    Assert-Equal ([IO.Path]::GetFileName($indexPath)) 'index.json' 'evidence index filename must be fixed'
    Assert-Equal ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($indexPath))) $executionId 'evidence index must live under execution_id directory'

    $record = [ordered]@{
        evidence_id = 'artifact-12-34'
        gate_id = 'ARTIFACT'
        type = 'ARTIFACT_MANIFEST'
        producer = 'test'
        source_sha = ('a' * 40)
        github_run_id = 12
        artifact_id = 34
        candidate_sha256 = ('b' * 64)
        device_build_id = ''
        ref = 'github-artifact:34'
        sha256 = ('c' * 64)
        observed_at = '2026-09-08T12:00:00+00:00'
        result = 'PASS'
    }

    Add-ArthurEvidenceRecord -Path $indexPath -Record $record | Out-Null
    $index = Read-ArthurEvidenceIndex -Path $indexPath
    Assert-Equal $index.schema_version 1 'evidence index schema must be version 1'
    Assert-Equal $index.execution_id $executionId 'index must retain execution identity'
    Assert-Equal @($index.evidence).Count 1 'first evidence record must persist once'
    Assert-Equal $index.evidence[0].candidate_sha256 ('b' * 64) 'candidate identity must persist'

    $sameIdentity = [ordered]@{}
    foreach ($key in $record.Keys) { $sameIdentity[$key] = $record[$key] }
    $sameIdentity.observed_at = '2026-09-08T12:01:00+00:00'
    Add-ArthurEvidenceRecord -Path $indexPath -Record $sameIdentity | Out-Null
    $index2 = Read-ArthurEvidenceIndex -Path $indexPath
    Assert-Equal @($index2.evidence).Count 1 'idempotent evidence update must not duplicate evidence_id'
    Assert-Equal $index2.evidence[0].observed_at '2026-09-08T12:01:00+00:00' 'same identity may refresh observation timestamp'

    $conflict = [ordered]@{}
    foreach ($key in $record.Keys) { $conflict[$key] = $record[$key] }
    $conflict.candidate_sha256 = ('d' * 64)
    Assert-Throws { Add-ArthurEvidenceRecord -Path $indexPath -Record $conflict | Out-Null } 'same evidence_id with different identity must fail closed'

    $found = @(Find-ArthurGateEvidence -Path $indexPath -GateId 'ARTIFACT')
    Assert-Equal $found.Count 1 'gate lookup must return matching evidence'
    Assert-Equal @(Find-ArthurGateEvidence -Path $indexPath -GateId 'WIFI').Count 0 'gate lookup must not return unrelated evidence'

    $badTime = [ordered]@{}
    foreach ($key in $record.Keys) { $badTime[$key] = $record[$key] }
    $badTime.evidence_id = 'bad-time'
    $badTime.observed_at = '2026-09-08 12:00:00'
    Assert-Throws { Add-ArthurEvidenceRecord -Path $indexPath -Record $badTime | Out-Null } 'evidence timestamp must include an offset'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'ARTHUR_EVIDENCE_INDEX=PASS'
