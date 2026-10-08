$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot '.github\workflows\arthur-ssh-auth-recovery.yml'
if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    throw 'TEST_FAIL: the narrowly scoped SSH recovery workflow must exist.'
}
$workflow = Get-Content -Raw -LiteralPath $workflowPath
foreach ($requiredSourceLoad in @(
    'git -C $sourceRoot status --porcelain --untracked-files=normal',
    'git -C $sourceRoot cat-file -e "${env:GITHUB_SHA}^{commit}"',
    'git -c http.sslBackend=openssl -C $sourceRoot fetch --no-tags origin $env:GITHUB_SHA',
    'git -C $sourceRoot checkout --detach $env:GITHUB_SHA'
)) {
    if (-not $workflow.Contains($requiredSourceLoad)) {
        throw "TEST_FAIL: workflow must load the exact authorized source safely: $requiredSourceLoad"
    }
}
if ($workflow -match '(?m)^\s*uses:\s*actions/') {
    throw 'TEST_FAIL: recovery workflow must not depend on downloading external actions.'
}

foreach ($required in @(
    "'on':`n  workflow_dispatch:",
    '- self-hosted',
    '- windows',
    '- x64',
    '- xinzhaowrt-controller',
    'ARTHUR_ROOT_PASSWORD: ${{ secrets.ARTHUR_ROOT_PASSWORD }}',
    'scripts\ensure-arthur-unattended-access.ps1',
    'Assert-ArthurEthernetIdentity',
    'Test-ArthurReadOnlyAuthenticatedEvidence',
    "Write-Host 'RUNNER_KEY_AUTH=PASS'",
    "Write-Host 'SSH_HOST_TRUST=PASS'"
)) {
    if ($workflow -notmatch [regex]::Escape($required)) {
        throw "TEST_FAIL: recovery workflow is missing required safeguard or runner binding: $required"
    }
}

if ($workflow -match '(?m)^\s*(push|pull_request|workflow_run):') {
    throw 'TEST_FAIL: SSH recovery must be workflow_dispatch only.'
}
if ($workflow -match 'StrictHostKeyChecking=no|sysupgrade|reboot|\bmtd\b|\bdd\s') {
    throw 'TEST_FAIL: SSH recovery must not bypass host trust or perform firmware/storage operations.'
}

$routeIndex = $workflow.IndexOf('Assert-ArthurEthernetIdentity',[StringComparison]::Ordinal)
$passwordIndex = $workflow.IndexOf('Invoke-ArthurSshProbe',[StringComparison]::Ordinal)
$readOnlyIndex = $workflow.IndexOf('Test-ArthurReadOnlyAuthenticatedEvidence',[StringComparison]::Ordinal)
$writeIndex = $workflow.IndexOf('Ensure-ArthurUnattendedAccess',[StringComparison]::Ordinal)
if (-not ($routeIndex -lt $passwordIndex -and $passwordIndex -lt $readOnlyIndex -and $readOnlyIndex -lt $writeIndex)) {
    throw 'TEST_FAIL: Ethernet/HTTP and password-authenticated device identity must pass before invoking the key repair.'
}

$lines = Get-Content -LiteralPath $workflowPath
$runBlocks = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ([string]$lines[$i] -ne '        run: |') { continue }
    $scriptLines = @()
    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        $line = [string]$lines[$j]
        if ($line.Length -gt 0 -and $line -notmatch '^ {10}') { break }
        if ($line.Length -gt 0) { $scriptLines += $line.Substring(10) } else { $scriptLines += '' }
    }
    $runBlocks += ,$scriptLines
}
if ($runBlocks.Count -lt 2) { throw 'TEST_FAIL: both source loading and recovery PowerShell steps must exist.' }
foreach ($scriptLines in $runBlocks) {
    $temporaryScript = Join-Path ([System.IO.Path]::GetTempPath()) ("arthur-ssh-workflow-parse-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllLines($temporaryScript,$scriptLines,[Text.UTF8Encoding]::new($false))
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($temporaryScript,[ref]$tokens,[ref]$errors)
        if ($errors.Count -gt 0) {
            throw "TEST_FAIL: workflow PowerShell syntax is invalid: $(($errors | ForEach-Object Message) -join '; ')"
        }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporaryScript
    }
}
Write-Output 'ARTHUR_SSH_AUTH_RECOVERY_WORKFLOW_CONTRACT=PASS'
