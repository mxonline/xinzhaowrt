$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$verify = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'scripts\real-device-verify.ps1')
$upload = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'scripts\real-device-upload-oom.ps1')

foreach ($source in @($verify, $upload)) {
    if ($source -notmatch 'function Invoke-NativeCaptured') {
        throw 'Native SSH callers must use Invoke-NativeCaptured.'
    }
    if ($source -notmatch '\$previousErrorActionPreference\s*=\s*\$ErrorActionPreference') {
        throw 'Native SSH capture must preserve the caller ErrorActionPreference.'
    }
    if ($source -notmatch '\$ErrorActionPreference\s*=\s*[''\"]Continue[''\"]') {
        throw 'Native SSH capture must use Continue while collecting stderr.'
    }
    if ($source -notmatch '\$exitCode\s*=\s*\$LASTEXITCODE') {
        throw 'Native SSH capture must save LASTEXITCODE immediately.'
    }
    if ($source -notmatch '\$ErrorActionPreference\s*=\s*\$previousErrorActionPreference') {
        throw 'Native SSH capture must restore the caller ErrorActionPreference.'
    }
}

if ($verify -match '@\(&\s*ssh\b') {
    throw 'real-device-verify.ps1 must not invoke ssh directly from Invoke-Remote.'
}
if ($upload -match '\$result\s*=\s*&\s*ssh\b') {
    throw 'real-device-upload-oom.ps1 must not invoke ssh directly from Invoke-TargetSsh.'
}

Write-Output 'REAL_DEVICE_NATIVE_CAPTURE_TEST=PASS'
