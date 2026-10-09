$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$accessScript = Join-Path $projectRoot 'scripts\ensure-arthur-unattended-access.ps1'
$git = Get-Command git.exe -ErrorAction Stop
$gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
$bashPath = Join-Path $gitRoot 'usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
    $bashPath = Join-Path $gitRoot 'bin\bash.exe'
}
if (-not (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
    throw "ARTHUR_NATIVE_STDIN_TEST_BASH_NOT_FOUND git_root=$gitRoot"
}

. $accessScript
$scriptText = "printf 'STDIN_COMMAND=PASS'; exit 7"
$result = Invoke-ArthurAccessNative -FilePath $bashPath -Arguments @('-s') -InputText $scriptText
if ($result.ExitCode -ne 7) {
    throw "STDIN_TRANSPORT_EXIT_CODE_MISMATCH expected=7 actual=$($result.ExitCode)"
}
if ($result.Output -notmatch 'STDIN_COMMAND=PASS') {
    throw 'STDIN_TRANSPORT_COMMAND_CONTENT_MISMATCH'
}

Write-Output 'ARTHUR_NATIVE_STDIN_TRANSPORT=PASS'
