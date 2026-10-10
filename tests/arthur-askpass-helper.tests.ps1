$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$helperScript = Join-Path $root 'scripts\ensure-arthur-unattended-access.ps1'
. $helperScript

$originalPassword = $env:ARTHUR_ROOT_PASSWORD
$env:ARTHUR_ROOT_PASSWORD = 'codex-askpass-test-fixture'
$helper = $null
try {
    $helper = Get-ArthurAskPassHelper
    $actual = @(& $helper)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $actual.Count -ne 1 -or [string]$actual[0] -cne 'codex-askpass-test-fixture') {
        throw 'TEST_FAIL: askpass helper must read its value from the runtime environment and return it to OpenSSH.'
    }
    Write-Output 'ARTHUR_ASKPASS_RUNTIME_COMPATIBILITY=PASS'
}
finally {
    if ($helper -and (Test-Path -LiteralPath $helper)) { Remove-Item -Force -LiteralPath $helper }
    $script:ArthurAccessAskPassExe = $null
    if ($null -eq $originalPassword) { Remove-Item Env:ARTHUR_ROOT_PASSWORD -ErrorAction SilentlyContinue }
    else { $env:ARTHUR_ROOT_PASSWORD = $originalPassword }
}
