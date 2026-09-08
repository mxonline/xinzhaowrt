Set-StrictMode -Version Latest

$stateContractPath = Join-Path $PSScriptRoot 'arthur-state-contract.ps1'
if (-not (Test-Path -LiteralPath $stateContractPath -PathType Leaf)) {
    throw 'ARTHUR_EVIDENCE_STATE_CONTRACT_MISSING'
}
. $stateContractPath

function Get-ArthurEvidenceIndexPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$ExecutionId
    )

    $execution = $ExecutionId.Trim().ToLowerInvariant()
    if ($execution -notmatch '^arthur-[a-z0-9-]+-[0-9a-f]{7}-\d{8}$') {
        throw "ARTHUR_EVIDENCE_EXECUTION_ID_INVALID=$ExecutionId"
    }
    return (Join-Path $Root (Join-Path 'production' (Join-Path 'evidence' (Join-Path $execution 'index.json'))))
}

function Read-ArthurEvidenceIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $index = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 30
    }
    catch {
        throw "ARTHUR_EVIDENCE_INDEX_INVALID_JSON=$Path $($_.Exception.Message)"
    }
    if ([int]$index.schema_version -ne 1) { throw "ARTHUR_EVIDENCE_INDEX_SCHEMA_INVALID=$Path" }
    if ([string]::IsNullOrWhiteSpace([string]$index.execution_id)) { throw "ARTHUR_EVIDENCE_INDEX_EXECUTION_ID_MISSING=$Path" }
    if (-not $index.PSObject.Properties['evidence']) { throw "ARTHUR_EVIDENCE_INDEX_RECORDS_MISSING=$Path" }
    return $index
}

function ConvertTo-ArthurEvidenceSha {
    param([object]$Value,[int[]]$AllowedLengths,[string]$Field,[switch]$AllowEmpty)
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) { return '' }
        throw "ARTHUR_EVIDENCE_${Field}_MISSING"
    }
    if ($text -notmatch '^[0-9a-f]+$' -or $AllowedLengths -notcontains $text.Length) {
        throw "ARTHUR_EVIDENCE_${Field}_INVALID=$Value"
    }
    return $text
}

function ConvertTo-ArthurEvidenceRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Record)

    foreach ($required in @('evidence_id','gate_id','type','producer','ref','observed_at','result')) {
        $value = [string](Get-ArthurStateMember $Record $required)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "ARTHUR_EVIDENCE_FIELD_MISSING=$required" }
    }

    $timestamp = [string](Get-ArthurStateMember $Record 'observed_at')
    if ($timestamp -notmatch '(?:Z|[+-]\d{2}:\d{2})$') { throw "ARTHUR_EVIDENCE_TIME_NOT_ABSOLUTE=$timestamp" }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($timestamp,[ref]$parsed)) { throw "ARTHUR_EVIDENCE_TIME_INVALID=$timestamp" }

    $sourceSha = ConvertTo-ArthurEvidenceSha -Value (Get-ArthurStateMember $Record 'source_sha') -AllowedLengths @(40,64) -Field 'SOURCE_SHA' -AllowEmpty
    $candidateSha = ConvertTo-ArthurEvidenceSha -Value (Get-ArthurStateMember $Record 'candidate_sha256') -AllowedLengths @(64) -Field 'CANDIDATE_SHA256' -AllowEmpty
    $contentSha = ConvertTo-ArthurEvidenceSha -Value (Get-ArthurStateMember $Record 'sha256') -AllowedLengths @(64) -Field 'SHA256' -AllowEmpty

    $runValue = Get-ArthurStateMember $Record 'github_run_id'
    $artifactValue = Get-ArthurStateMember $Record 'artifact_id'
    $runId = if ($null -eq $runValue -or [string]::IsNullOrWhiteSpace([string]$runValue)) { [long]0 } else { [long]$runValue }
    $artifactId = if ($null -eq $artifactValue -or [string]::IsNullOrWhiteSpace([string]$artifactValue)) { [long]0 } else { [long]$artifactValue }
    if ($runId -lt 0) { throw 'ARTHUR_EVIDENCE_GITHUB_RUN_ID_INVALID' }
    if ($artifactId -lt 0) { throw 'ARTHUR_EVIDENCE_ARTIFACT_ID_INVALID' }

    return [pscustomobject][ordered]@{
        evidence_id = ([string](Get-ArthurStateMember $Record 'evidence_id')).Trim()
        gate_id = ([string](Get-ArthurStateMember $Record 'gate_id')).Trim()
        type = ([string](Get-ArthurStateMember $Record 'type')).Trim()
        producer = ([string](Get-ArthurStateMember $Record 'producer')).Trim()
        source_sha = $sourceSha
        github_run_id = $runId
        artifact_id = $artifactId
        candidate_sha256 = $candidateSha
        device_build_id = ([string](Get-ArthurStateMember $Record 'device_build_id')).Trim()
        ref = ([string](Get-ArthurStateMember $Record 'ref')).Trim()
        sha256 = $contentSha
        observed_at = $timestamp
        result = ([string](Get-ArthurStateMember $Record 'result')).Trim()
    }
}

function Get-ArthurEvidenceIdentityHash {
    param([Parameter(Mandatory=$true)][object]$Record)
    $identity = [ordered]@{
        evidence_id = [string](Get-ArthurStateMember $Record 'evidence_id')
        gate_id = [string](Get-ArthurStateMember $Record 'gate_id')
        type = [string](Get-ArthurStateMember $Record 'type')
        producer = [string](Get-ArthurStateMember $Record 'producer')
        source_sha = [string](Get-ArthurStateMember $Record 'source_sha')
        github_run_id = [long](Get-ArthurStateMember $Record 'github_run_id')
        artifact_id = [long](Get-ArthurStateMember $Record 'artifact_id')
        candidate_sha256 = [string](Get-ArthurStateMember $Record 'candidate_sha256')
        device_build_id = [string](Get-ArthurStateMember $Record 'device_build_id')
        ref = [string](Get-ArthurStateMember $Record 'ref')
        sha256 = [string](Get-ArthurStateMember $Record 'sha256')
        result = [string](Get-ArthurStateMember $Record 'result')
    }
    return (Get-ArthurStateSha256 -Text ($identity | ConvertTo-Json -Compress -Depth 20))
}

function Write-ArthurEvidenceIndex {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object]$Index)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $tmp = "$Path.$PID.tmp"
    $json = $Index | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($tmp,$json + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Add-ArthurEvidenceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][object]$Record
    )

    $normalized = ConvertTo-ArthurEvidenceRecord -Record $Record
    $executionId = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Path)).ToLowerInvariant()
    if ($executionId -notmatch '^arthur-[a-z0-9-]+-[0-9a-f]{7}-\d{8}$') {
        throw "ARTHUR_EVIDENCE_PATH_EXECUTION_ID_INVALID=$Path"
    }

    $index = Read-ArthurEvidenceIndex -Path $Path
    if ($null -eq $index) {
        $index = [pscustomobject][ordered]@{
            schema_version = 1
            execution_id = $executionId
            evidence = @()
        }
    }
    elseif ([string]$index.execution_id -ne $executionId) {
        throw "ARTHUR_EVIDENCE_INDEX_EXECUTION_ID_MISMATCH=$Path"
    }

    $records = @($index.evidence)
    $existing = @($records | Where-Object { [string]$_.evidence_id -eq [string]$normalized.evidence_id })
    if ($existing.Count -gt 1) { throw "ARTHUR_EVIDENCE_DUPLICATE_ID_CORRUPTION=$($normalized.evidence_id)" }
    if ($existing.Count -eq 1) {
        $oldHash = Get-ArthurEvidenceIdentityHash -Record $existing[0]
        $newHash = Get-ArthurEvidenceIdentityHash -Record $normalized
        if ($oldHash -ne $newHash) { throw "ARTHUR_EVIDENCE_IDENTITY_CONFLICT=$($normalized.evidence_id)" }
        $records = @($records | Where-Object { [string]$_.evidence_id -ne [string]$normalized.evidence_id })
    }
    $records += $normalized
    $index.evidence = @($records)
    Write-ArthurEvidenceIndex -Path $Path -Index $index
    return $normalized
}

function Find-ArthurGateEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$GateId
    )
    $index = Read-ArthurEvidenceIndex -Path $Path
    if ($null -eq $index) { return @() }
    return @($index.evidence | Where-Object { [string]$_.gate_id -eq $GateId })
}
