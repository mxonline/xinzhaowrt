[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaseRef,
    [string]$LedgerPath = 'production/firmware-events.jsonl'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localLedger = Join-Path $root ($LedgerPath -replace '/', [IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $localLedger -PathType Leaf)) {
    Write-Error "FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED: current ledger missing path=$LedgerPath"
    exit 1
}

Push-Location $root
try {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $resolvedBase = (& git rev-parse --verify "${BaseRef}^{commit}" 2>&1 | Out-String).Trim()
        $resolveCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($resolveCode -ne 0 -or $resolvedBase -notmatch '^[0-9a-fA-F]{40}$') {
        Write-Error "FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED: invalid base ref=$BaseRef"
        exit 1
    }

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git cat-file -e "${resolvedBase}:${LedgerPath}" 2>$null
        $baseHasLedger = ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $old }

    if (-not $baseHasLedger) {
        Write-Host "FIRMWARE_EVENT_HISTORY_APPEND_ONLY=PASS mode=INITIAL_INTRODUCTION base=$resolvedBase"
        exit 0
    }

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $baseLines = @(& git show "${resolvedBase}:${LedgerPath}" 2>&1)
        $showCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($showCode -ne 0) {
        Write-Error "FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED: cannot read base ledger base=$resolvedBase"
        exit 1
    }

    $currentLines = @(Get-Content -LiteralPath $localLedger)
    if ($currentLines.Count -lt $baseLines.Count) {
        Write-Error "FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED: ledger shortened base_lines=$($baseLines.Count) current_lines=$($currentLines.Count)"
        exit 1
    }

    for ($i = 0; $i -lt $baseLines.Count; $i++) {
        if (-not [string]::Equals([string]$currentLines[$i], [string]$baseLines[$i], [StringComparison]::Ordinal)) {
            $lineNumber = $i + 1
            Write-Error "FIRMWARE_EVENT_HISTORY_REWRITE_BLOCKED: historical line changed line=$lineNumber"
            exit 1
        }
    }

    $appended = $currentLines.Count - $baseLines.Count
    Write-Host "FIRMWARE_EVENT_HISTORY_APPEND_ONLY=PASS base_lines=$($baseLines.Count) appended_lines=$appended base=$resolvedBase"
    exit 0
}
finally {
    Pop-Location
}
