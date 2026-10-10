$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $root '.github\workflows\arthur-post-release-device-test.yml'
$requestPath = Join-Path $root 'production\post-release-device-test-request.json'
$deviceTestPath = Join-Path $root 'scripts\arthur-post-release-v016-device-test.ps1'
$workflow = Get-Content -Raw -LiteralPath $workflowPath
$setupName = '      - name: Install pinned PowerShell 7 runtime'
$executeName = '      - name: Execute exact-release flash and base/file-management acceptance'
$setupIndex = $workflow.IndexOf($setupName, [StringComparison]::Ordinal)
$executeIndex = $workflow.IndexOf($executeName, [StringComparison]::Ordinal)

if ($setupIndex -lt 0 -or $executeIndex -lt 0 -or $setupIndex -ge $executeIndex) {
    throw 'TEST_FAIL: a pinned PowerShell 7 bootstrap must run before the device-test script.'
}

$stepEnd = $workflow.IndexOf("`n      - name:", $setupIndex, [StringComparison]::Ordinal)
if ($stepEnd -lt 0) { $stepEnd = $workflow.Length }
$setupStep = $workflow.Substring($setupIndex, $stepEnd - $setupIndex)
$expectedUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
$expectedSha256 = '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860'
foreach ($required in @(
    $expectedUrl,
    $expectedSha256,
    'Get-FileHash',
    'Expand-Archive',
    'pwsh.exe',
    '$env:GITHUB_PATH',
    'UTF8Encoding'
)) {
    if (-not $setupStep.Contains($required)) {
        throw "TEST_FAIL: PowerShell bootstrap is missing pinned/verified setup behavior: $required"
    }
}

$hashIndex = $setupStep.IndexOf('Get-FileHash', [StringComparison]::Ordinal)
$expandIndex = $setupStep.IndexOf('Expand-Archive', [StringComparison]::Ordinal)
if ($hashIndex -lt 0 -or $expandIndex -lt 0 -or $hashIndex -ge $expandIndex) {
    throw 'TEST_FAIL: PowerShell archive SHA-256 must be checked before extraction.'
}
$downloadLoopIndex = $setupStep.IndexOf('for ($attempt = 1; $attempt -le 3; $attempt++)', [StringComparison]::Ordinal)
$downloadCallIndex = $setupStep.IndexOf('Invoke-WebRequest', [StringComparison]::Ordinal)
if ($downloadLoopIndex -lt 0 -or $downloadCallIndex -lt $downloadLoopIndex -or $setupStep -notmatch '(?i)unexpected EOF\|0 bytes from the transport stream\|TLS handshake timeout\|connection reset' -or $setupStep -notmatch 'Start-Sleep -Seconds') {
    throw 'TEST_FAIL: official PowerShell archive download must retry only bounded transient transport failures.'
}

$lines = $setupStep -split "`r?`n"
$runStart = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq '        run: |') { $runStart = $i + 1; break }
}
if ($runStart -lt 0) { throw 'TEST_FAIL: PowerShell bootstrap must use a PowerShell run step.' }
$scriptLines = @()
for ($i = $runStart; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    if ($line.Length -gt 0 -and $line -notmatch '^ {10}') { break }
    if ($line.Length -gt 0) { $scriptLines += $line.Substring(10) } else { $scriptLines += '' }
}
$temporaryScript = Join-Path ([System.IO.Path]::GetTempPath()) ("arthur-pwsh-bootstrap-parse-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllLines($temporaryScript, $scriptLines, [Text.UTF8Encoding]::new($false))
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($temporaryScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "TEST_FAIL: PowerShell bootstrap syntax is invalid: $(($errors | ForEach-Object Message) -join '; ')"
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporaryScript
}

$deviceTest = Get-Content -Raw -LiteralPath $deviceTestPath
$scpFunction = [regex]::Match($deviceTest, '(?ms)^function Invoke-StrictScp \{(?<body>.*?)(?=^function )')
$scpArguments = if ($scpFunction.Success) { $scpFunction.Groups['body'].Value } else { '' }
if ($scpArguments.IndexOf("'-O'", [StringComparison]::Ordinal) -lt 0) {
    throw 'TEST_FAIL: Arthur upload must use OpenSSH legacy SCP mode for a target without sftp-server.'
}

$githubRead = [regex]::Match($deviceTest, '(?ms)^function Invoke-GitHubRead \{(?<body>.*?)(?=^function )')
$githubReadBody = if ($githubRead.Success) { $githubRead.Groups['body'].Value } else { '' }
if (-not $githubRead.Success -or -not $githubReadBody.Contains('$attempt -le 3') -or $githubReadBody -notmatch '(?i)\bEOF\b|TLS handshake timeout') {
    throw 'TEST_FAIL: read-only GitHub operations must retry transient EOF/TLS failures a bounded number of times.'
}
if ($deviceTest -match 'Invoke-NativeCaptured\s+-FilePath\s+\$gh') {
    throw 'TEST_FAIL: GitHub release/API reads and downloads must use the transient-network retry wrapper.'
}

$request = Get-Content -Raw -LiteralPath $requestPath | ConvertFrom-Json
if ([int]$request.retry_sequence -ne 5 -or [long]$request.previous_run_id -ne 38027280140L -or $request.previous_run_device_write_started -ne $false) {
    throw 'TEST_FAIL: recovery request must record the completed no-write GitHub API failure before triggering one retry.'
}
if ([string]$request.retry_reason -notmatch 'PowerShell.*unexpected EOF|archive download.*unexpected EOF') {
    throw 'TEST_FAIL: retry reason must identify the actual pre-device PowerShell archive transport failure.'
}

Write-Output 'ARTHUR_POST_RELEASE_DEVICE_TEST_POWERSHELL_BOOTSTRAP=PASS'
Write-Output 'ARTHUR_POST_RELEASE_DEVICE_TEST_RETRY_AUTHORITY=PASS'
