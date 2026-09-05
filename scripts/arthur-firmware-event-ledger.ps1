Set-StrictMode -Version Latest

function Get-ArthurFirmwareEventHash {
    param(
        [long]$Seq,
        [string]$Timestamp,
        [string]$Event,
        [string]$Stage,
        [string]$Source,
        [string]$PrevHash,
        [object]$Data
    )
    $dataJson = if ($null -eq $Data) { '{}' } else { $Data | ConvertTo-Json -Compress -Depth 30 }
    $payload = "{0}`n{1}`n{2}`n{3}`n{4}`n{5}`n{6}" -f $Seq,$Timestamp,$Event,$Stage,$Source,$PrevHash,$dataJson
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ArthurFirmwareEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $events = @()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            # PowerShell 7 may auto-convert ISO 8601 JSON strings to DateTime and lose
            # the original offset when later stringified. Preserve the exact wire value
            # used by the hash chain so validation is stable across PS 5.1/7.x.
            $timeMatch = [regex]::Match($line, '"time"\s*:\s*"(?<time>[^"\\]*(?:\\.[^"\\]*)*)"')
            if (-not $timeMatch.Success) { throw 'missing time string' }
            $timeLiteral = $timeMatch.Groups['time'].Value
            $timeLiteral = '"' + $timeLiteral + '"' | ConvertFrom-Json
            $entry.time = [string]$timeLiteral
            $events += $entry
        }
        catch { throw "FIRMWARE_EVENT_LEDGER_INVALID_JSON: $($_.Exception.Message)" }
    }
    return @($events)
}

function Test-ArthurFirmwareEventLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $events = @(Get-ArthurFirmwareEvents -Path $Path)
    $expectedSeq = 1L
    $expectedPrev = 'GENESIS'
    foreach ($entry in $events) {
        if ([long]$entry.seq -ne $expectedSeq) { throw "FIRMWARE_EVENT_LEDGER_SEQUENCE_INVALID: expected=$expectedSeq actual=$($entry.seq)" }
        if ([string]$entry.prev_hash -ne $expectedPrev) { throw "FIRMWARE_EVENT_LEDGER_CHAIN_INVALID: seq=$expectedSeq" }
        $timestamp = [string]$entry.time
        if ($timestamp -notmatch '(?:Z|[+-]\d{2}:\d{2})$') { throw "FIRMWARE_EVENT_LEDGER_TIME_NOT_ABSOLUTE: seq=$expectedSeq time=$timestamp" }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($timestamp,[ref]$parsed)) { throw "FIRMWARE_EVENT_LEDGER_TIME_INVALID: seq=$expectedSeq time=$timestamp" }
        $data = if ($entry.PSObject.Properties['data']) { $entry.data } else { [pscustomobject]@{} }
        $actual = Get-ArthurFirmwareEventHash -Seq ([long]$entry.seq) -Timestamp $timestamp -Event ([string]$entry.event) -Stage ([string]$entry.stage) -Source ([string]$entry.source) -PrevHash ([string]$entry.prev_hash) -Data $data
        if ($actual -ne [string]$entry.event_hash) { throw "FIRMWARE_EVENT_LEDGER_HASH_INVALID: seq=$expectedSeq" }
        $expectedPrev = [string]$entry.event_hash
        $expectedSeq++
    }
    return $true
}

function Add-ArthurFirmwareEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Event,
        [string]$Stage = '',
        [Parameter(Mandatory=$true)][string]$Source,
        [string]$Timestamp = '',
        [object]$Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) { $Timestamp = [DateTimeOffset]::UtcNow.ToString('o') }
    if ($Timestamp -notmatch '(?:Z|[+-]\d{2}:\d{2})$') { throw "FIRMWARE_EVENT_TIME_MUST_BE_ISO8601_WITH_OFFSET: $Timestamp" }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp,[ref]$parsed)) { throw "FIRMWARE_EVENT_TIME_INVALID: $Timestamp" }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { [IO.File]::WriteAllText($Path,'',[Text.UTF8Encoding]::new($false)) }

    [void](Test-ArthurFirmwareEventLedger -Path $Path)
    $events = @(Get-ArthurFirmwareEvents -Path $Path)
    $seq = [long]$events.Count + 1L
    $prevHash = if ($events.Count -gt 0) { [string]$events[-1].event_hash } else { 'GENESIS' }
    if ($null -eq $Data) { $Data = [ordered]@{} }
    $eventHash = Get-ArthurFirmwareEventHash -Seq $seq -Timestamp $Timestamp -Event $Event -Stage $Stage -Source $Source -PrevHash $prevHash -Data $Data
    $entry = [ordered]@{
        schema_version = 1
        seq = $seq
        time = $Timestamp
        event = $Event
        stage = $Stage
        source = $Source
        data = $Data
        prev_hash = $prevHash
        event_hash = $eventHash
    }
    $json = $entry | ConvertTo-Json -Compress -Depth 30
    [IO.File]::AppendAllText($Path,$json + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    return ($json | ConvertFrom-Json)
}
