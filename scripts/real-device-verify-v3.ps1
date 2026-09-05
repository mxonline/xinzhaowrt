param(
    [string]$Candidate = 'prebuild-current-router',

    [Parameter(Mandatory = $true)]
    [string]$Commit,

    [string]$Target = 'root@192.168.6.1',

    [string]$LuciCookieFile = $env:ARTHUR_LUCI_COOKIE_FILE,

    [ValidateSet('Prebuild','PostFlash')]
    [string]$Mode = 'Prebuild'
)

$ErrorActionPreference = 'Stop'

$BaseScript = Join-Path $PSScriptRoot 'real-device-verify.ps1'
if (-not (Test-Path $BaseScript)) {
    throw "Base real-device verification script is missing: $BaseScript"
}

if ($Mode -eq 'PostFlash' -and $Candidate -notmatch '^arthur-(known-good|update)-\d+$') {
    throw "PostFlash verification requires a real Candidate tag: $Candidate"
}
if ($Candidate -match '33462873812') {
    throw 'REJECTED_FOR_RELEASE: candidate 33462873812 is REAL_DEVICE_VERIFY_INVALIDATED and may not be reflashed or released.'
}

if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw "Commit must be a full 40-character Git SHA: $Commit"
}

if ($Target -notmatch '^[A-Za-z0-9._-]+@([0-9]{1,3}(?:\.[0-9]{1,3}){3})$') {
    throw "Target must look like root@192.168.6.1: $Target"
}

$HostIp = $Matches[1]
Write-Host "REAL_DEVICE_V3_TARGET=$Target"
Write-Host "REAL_DEVICE_V3_CANDIDATE=$Candidate"
Write-Host "REAL_DEVICE_V3_COMMIT=$Commit"
Write-Host "REAL_DEVICE_V3_MODE=$Mode"

& pwsh -NoProfile -ExecutionPolicy Bypass -File $BaseScript -DeviceIp $HostIp -Candidate $Candidate -Commit $Commit -LuciCookieFile $LuciCookieFile -Mode $Mode
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
