$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$accessScript = Join-Path $projectRoot 'scripts\ensure-arthur-unattended-access.ps1'
$expected = 'test-only-askpass-value'
$script:ArthurAccessAskPassExe = $null
$env:ARTHUR_ROOT_PASSWORD = $expected

try {
    . $accessScript
    $askPass = Get-ArthurAskPassHelper
    if ([IO.Path]::GetExtension($askPass) -ne '.cmd') {
        throw "Askpass helper must use a PowerShell-version-independent .cmd wrapper, got: $askPass"
    }
    $actual = (& $askPass 'Password:').Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) {
        throw 'Askpass helper did not return the environment-provided credential.'
    }

    $keyPath = Join-Path ([IO.Path]::GetTempPath()) ('xinzhaowrt-empty-passphrase-' + [Guid]::NewGuid().ToString('N'))
    try {
        $keygen = Get-ArthurSshTool 'ssh-keygen'
        $keygenResult = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $keyPath)
        if ($keygenResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $keyPath)) {
            throw "Native invocation must preserve ssh-keygen's empty passphrase argument."
        }
    }
    finally {
        Remove-Item -LiteralPath $keyPath, ($keyPath + '.pub') -Force -ErrorAction SilentlyContinue
    }
    Write-Output 'ARTHUR_ACCESS_ASKPASS_TEST=PASS'
}
finally {
    if ($script:ArthurAccessAskPassExe -and (Test-Path -LiteralPath $script:ArthurAccessAskPassExe)) {
        Remove-Item -LiteralPath $script:ArthurAccessAskPassExe -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:ARTHUR_ROOT_PASSWORD -ErrorAction SilentlyContinue
    $script:ArthurAccessAskPassExe = $null
}
