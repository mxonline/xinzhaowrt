param(
    [Parameter(Mandatory = $true)]
    [string]$Candidate,

    [Parameter(Mandatory = $true)]
    [string]$Commit,

    [string]$Target = 'root@192.168.1.1'
)

$ErrorActionPreference = 'Stop'

$BaseScript = Join-Path $PSScriptRoot 'real-device-verify.ps1'
$GeneratedScript = Join-Path $PSScriptRoot '.real-device-verify-v3.generated.ps1'

if (-not (Test-Path $BaseScript)) {
    throw "Base real-device verification script is missing: $BaseScript"
}

if ($Candidate -notmatch '^arthur-(known-good|update)-\d+$') {
    throw "Unsupported Candidate tag: $Candidate"
}

if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw "Commit must be a full 40-character Git SHA: $Commit"
}

if ($Target -notmatch '^[A-Za-z0-9._-]+@([0-9]{1,3}(?:\.[0-9]{1,3}){3})$') {
    throw "Target must look like root@192.168.1.1: $Target"
}

$HostIp = $Matches[1]
$source = Get-Content -Raw -Encoding UTF8 $BaseScript

$requiredMarkers = @(
    "`$Target = 'root@192.168.1.1'",
    "`$Candidate = 'arthur-known-good-32853100232'",
    "`$Commit = '236abeaaea06442aa0f8f34efd0b4464b35c5061'"
)

foreach ($marker in $requiredMarkers) {
    if (-not $source.Contains($marker)) {
        throw "Base verification script changed unexpectedly; missing marker: $marker"
    }
}

$source = $source.Replace("`$Target = 'root@192.168.1.1'", "`$Target = '$Target'")
$source = $source.Replace("`$Candidate = 'arthur-known-good-32853100232'", "`$Candidate = '$Candidate'")
$source = $source.Replace("`$Commit = '236abeaaea06442aa0f8f34efd0b4464b35c5061'", "`$Commit = '$Commit'")
$source = $source.Replace('192.168.1.1', $HostIp)

Set-Content -Path $GeneratedScript -Value $source -Encoding UTF8

try {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $GeneratedScript),
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        $errors | Format-List | Out-String | Write-Error
        throw 'Generated real-device verification script failed PowerShell parsing.'
    }

    Write-Host "REAL_DEVICE_V3_TARGET=$Target"
    Write-Host "REAL_DEVICE_V3_CANDIDATE=$Candidate"
    Write-Host "REAL_DEVICE_V3_COMMIT=$Commit"

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $GeneratedScript
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $GeneratedScript
}
