$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$resumePath = Join-Path $projectRoot 'scripts\arthur-postflash-resume.ps1'
$tokens = $null
$parseErrors = $null
$resumeAst = [Management.Automation.Language.Parser]::ParseFile($resumePath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "TEST_FAIL: PostFlash resume syntax invalid: $(($parseErrors | ForEach-Object Message) -join '; ')" }

$functionNames = @('ConvertTo-SanitizedPostFlashVerifierOutput','Get-PostFlashBaseFirstFailure','Complete-PostFlashBaseVerification')
foreach ($name in $functionNames) {
    $definition = $resumeAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name },$true)
    if (-not $definition) { throw "TEST_FAIL: PostFlash verifier output helper is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$savedWriteHost = Get-Item Function:\global:Write-Host -ErrorAction SilentlyContinue
$global:PostFlashVerifierTestHostMessages = @()
Set-Item Function:\global:Write-Host -Value {
    param([object]$Object)
    $global:PostFlashVerifierTestHostMessages += [string]$Object
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pfvo-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$savedPassword = [Environment]::GetEnvironmentVariable('ARTHUR_ROOT_PASSWORD','Process')
try {
    $env:ARTHUR_ROOT_PASSWORD = 'postflash-test-password-secret'
    $failureLog = Join-Path $testRoot 'failed-verifier.log'
    $failureOutput = @(
        'CHECK_A=PASS',
        'CHECK_B=FAIL reason=xxx',
        'CHECK_C=FAIL reason=later',
        'root password=postflash-test-password-secret',
        'Authorization: Bearer ghp_0123456789abcdefghijklmnop',
        'Cookie: sysauth_http=private-cookie-value',
        'ss://user:private-proxy-password@proxy.example.invalid:8388',
        '-----BEGIN OPENSSH PRIVATE KEY-----',
        'private-key-material',
        '-----END OPENSSH PRIVATE KEY-----'
    )

    $captured = ''
    $failure = ''
    try { $null = Complete-PostFlashBaseVerification -Output $failureOutput -ExitCode 1 -LogPath $failureLog }
    catch { $failure = [string]$_ }
    $captured = $global:PostFlashVerifierTestHostMessages -join [Environment]::NewLine

    if (-not (Test-Path -LiteralPath $failureLog -PathType Leaf)) { throw 'TEST_FAIL: failed verifier output was not written to the requested log file.' }
    $savedFailureText = Get-Content -Raw -LiteralPath $failureLog
    foreach ($text in @('CHECK_A=PASS','CHECK_B=FAIL reason=xxx','CHECK_C=FAIL reason=later')) {
        if (-not $captured.Contains($text) -or -not $savedFailureText.Contains($text)) {
            throw "TEST_FAIL: failed verifier output was not preserved in console and file: $text`nCAPTURED=$captured`nSAVED=$savedFailureText"
        }
    }
    if (-not $captured.Contains('POSTFLASH_BASE_FIRST_FAILURE=CHECK_B')) {
        throw "TEST_FAIL: exact first failure marker was not written to the action log.`nCAPTURED=$captured"
    }
    if (-not $captured.Contains('POSTFLASH_BASE_VERIFIER_OUTPUT_BEGIN') -or -not $captured.Contains('POSTFLASH_BASE_VERIFIER_OUTPUT_END')) {
        throw 'TEST_FAIL: sanitized verifier output delimiters were not written to the action log.'
    }
    if (-not $failure.Contains('POSTFLASH_BASE_VERIFICATION_FAILED exit=1')) { throw "TEST_FAIL: failure was not raised after emitting the first marker: $failure" }
    foreach ($secret in @('postflash-test-password-secret','0123456789abcdefghijklmnop','private-cookie-value','private-proxy-password','private-key-material')) {
        if ($captured.Contains($secret) -or $savedFailureText.Contains($secret)) { throw "TEST_FAIL: sensitive verifier content was not redacted: $secret" }
    }

    $passLog = Join-Path $testRoot 'passed-verifier.log'
    $passOutput = @('CHECK_A=PASS','CHECK_B=PASS')
    $global:PostFlashVerifierTestHostMessages = @()
    $null = Complete-PostFlashBaseVerification -Output $passOutput -ExitCode 0 -LogPath $passLog
    $passCaptured = $global:PostFlashVerifierTestHostMessages -join [Environment]::NewLine
    $continued = 'FILE_MANAGEMENT_CONTINUATION=REACHED'
    if (-not (Test-Path -LiteralPath $passLog -PathType Leaf) -or
        -not $passCaptured.Contains('POSTFLASH_BASE_VERIFICATION=PASS')) {
        throw 'TEST_FAIL: successful verifier result did not return for file-management checks.'
    }
    Write-Output $continued
    Write-Output 'ARTHUR_POSTFLASH_VERIFIER_FAILURE_OUTPUT=PASS'
    Write-Output 'ARTHUR_POSTFLASH_VERIFIER_SUCCESS_CONTINUES=PASS'
    Write-Output 'ARTHUR_POSTFLASH_VERIFIER_SECRET_REDACTION=PASS'
}
finally {
    [Environment]::SetEnvironmentVariable('ARTHUR_ROOT_PASSWORD',$savedPassword,'Process')
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $testRoot
    if ($savedWriteHost) { Set-Item Function:\global:Write-Host -Value $savedWriteHost.ScriptBlock }
    else { Remove-Item Function:\global:Write-Host -ErrorAction SilentlyContinue }
}
