[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bridgePath = Join-Path $repositoryRoot 'output\github-app-bridge\run-host-main-push.ps1'
$expectedProductionWorktree = 'C:\Users\chenz\Documents\xinzhaowrt\.worktrees\production-v015-main'
$expectedLocalHead = 'a2015d72aaf0d45df6d83b503881c3cf4b8e2200'
$expectedRemoteHead = 'd73744c68fe7794286a178e6c0c106727d07ee63'
$pwshPath = 'C:\Users\chenz\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Condition {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $Condition) { $failures.Add($Name) }
}

function Invoke-BridgeProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$RemoteUrl,
        [string]$GitExecutable
    )
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $bridgePath,
        '-RegressionProbe',
        '-RegressionWorktree', $Worktree,
        '-RegressionRemoteUrl', $RemoteUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($GitExecutable)) {
        $arguments += @('-RegressionGitExecutable', $GitExecutable)
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $pwshPath @arguments 2>&1)
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-GitChecked {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & git @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('GIT_FIXTURE_COMMAND_FAILED=' + ($Arguments -join ' ')) }
}

if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
    throw ('BRIDGE_MISSING=' + $bridgePath)
}
if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
    throw ('PWSH_MISSING=' + $pwshPath)
}

$bridgeText = Get-Content -Raw -LiteralPath $bridgePath
Assert-Condition ($bridgeText -notmatch '(?m)function\s+Get-OutputLine\b') 'OLD_PARSER_REMOVED'
Assert-Condition ($bridgeText -notmatch '\bGet-OutputLine\b') 'NO_GET_OUTPUT_LINE_REFERENCE'
Assert-Condition ($bridgeText -match [regex]::Escape("`$ProductionWorktree = '$expectedProductionWorktree'")) 'EXPLICIT_PRODUCTION_WORKTREE'
Assert-Condition ($bridgeText -match "'-C',\s*\`$ProductionWorktree,\s*'rev-parse',\s*'--show-toplevel'") 'DIRECT_REPO_ROOT_COMMAND'
Assert-Condition ($bridgeText -match "'-C',\s*\`$ProductionWorktree,\s*'rev-parse',\s*'HEAD'") 'DIRECT_HEAD_COMMAND'
Assert-Condition ($bridgeText -match "'-C',\s*\`$ProductionWorktree,\s*'status',\s*'--porcelain'") 'DIRECT_STATUS_COMMAND'
Assert-Condition ($bridgeText -match "'-C',\s*\`$ProductionWorktree,\s*'remote',\s*'get-url',\s*'origin'") 'DIRECT_ORIGIN_COMMAND'
Assert-Condition ($bridgeText -notmatch '(?m)\$root(Result|Line|Output)\b') 'NO_REPO_ROOT_OUTPUT_VARIABLE'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('xinzhaowrt-bridge-regression-' + [Guid]::NewGuid().ToString('N'))
$goodRemote = Join-Path $fixtureRoot 'mxonline\xinzhaowrt-good.git'
$badRemote = Join-Path $fixtureRoot 'mxonline\xinzhaowrt-bad.git'
$fakeGit = Join-Path $fixtureRoot 'fake-git.ps1'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $goodRemote) | Out-Null

try {
    Invoke-GitChecked @('-c', 'init.defaultBranch=main', 'init', '--bare', $goodRemote)
    Invoke-GitChecked @('-c', 'init.defaultBranch=main', 'init', '--bare', $badRemote)
    Invoke-GitChecked @('-C', $repositoryRoot, 'push', '--quiet', $goodRemote, ($expectedRemoteHead + ':refs/heads/main'))
    Invoke-GitChecked @('-C', $repositoryRoot, 'push', '--quiet', $badRemote, ($expectedLocalHead + ':refs/heads/main'))

    $fakeGitContent = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgumentList)
$joined = $ArgumentList -join ' '
if ($joined -match 'rev-parse --show-toplevel') {
    switch ($env:XZW_FAKE_ROOT_STDOUT_MODE) {
        'CRLF' { [Console]::Write("fake-root`r`n") }
        'LF' { [Console]::Write("fake-root`n") }
        'MULTILINE' { [Console]::Write("fake-root-one`nfake-root-two`n") }
        'EMPTY' { }
        default { [Console]::Write("fake-root`n") }
    }
    exit 0
}
if ($joined -match 'rev-parse HEAD') { Write-Output 'a2015d72aaf0d45df6d83b503881c3cf4b8e2200'; exit 0 }
if ($joined -match 'status --porcelain') { exit 0 }
if ($joined -match 'remote get-url origin') { Write-Output 'git@xinzhaowrt-github:mxonline/xinzhaowrt.git'; exit 0 }
if ($joined -match 'ls-remote') { Write-Output 'd73744c68fe7794286a178e6c0c106727d07ee63 refs/heads/main'; exit 0 }
exit 0
'@
    [IO.File]::WriteAllText($fakeGit, $fakeGitContent, [Text.UTF8Encoding]::new($false))

    foreach ($mode in @('CRLF', 'LF')) {
        $env:XZW_FAKE_ROOT_STDOUT_MODE = $mode
        $probe = Invoke-BridgeProbe -Worktree $expectedProductionWorktree -RemoteUrl $goodRemote -GitExecutable $fakeGit
        Assert-Condition ($probe.ExitCode -eq 0) ('ROOT_LINE_ENDING_' + $mode)
    }

    foreach ($mode in @('MULTILINE', 'EMPTY')) {
        $env:XZW_FAKE_ROOT_STDOUT_MODE = $mode
        $probe = Invoke-BridgeProbe -Worktree $expectedProductionWorktree -RemoteUrl $goodRemote -GitExecutable $fakeGit
        Assert-Condition ($probe.ExitCode -eq 0) ('HELPER_STDOUT_' + $mode + '_DOES_NOT_AFFECT_ROOT')
    }
    Remove-Item Env:XZW_FAKE_ROOT_STDOUT_MODE -ErrorAction SilentlyContinue

    $probe = Invoke-BridgeProbe -Worktree $expectedProductionWorktree -RemoteUrl $goodRemote
    Assert-Condition ($probe.ExitCode -eq 0) 'REAL_GIT_PRODUCTION_WORKTREE_PASS'

    $missingWorktree = Join-Path $fixtureRoot 'missing-production-worktree'
    $probe = Invoke-BridgeProbe -Worktree $missingWorktree -RemoteUrl $goodRemote
    Assert-Condition ($probe.ExitCode -ne 0 -and (($probe.Output -join "`n") -match 'PRODUCTION_WORKTREE_MISSING')) 'MISSING_WORKTREE_FAILS_CLOSED'

    $probe = Invoke-BridgeProbe -Worktree $repositoryRoot -RemoteUrl $goodRemote
    Assert-Condition ($probe.ExitCode -ne 0 -and (($probe.Output -join "`n") -match 'LOCAL_HEAD_MISMATCH')) 'HEAD_MISMATCH_FAILS_CLOSED'

    $probe = Invoke-BridgeProbe -Worktree $expectedProductionWorktree -RemoteUrl $badRemote
    Assert-Condition ($probe.ExitCode -ne 0 -and (($probe.Output -join "`n") -match 'REMOTE_HEAD_MISMATCH')) 'REMOTE_MAIN_MISMATCH_FAILS_CLOSED'
}
finally {
    Remove-Item Env:XZW_FAKE_ROOT_STDOUT_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Output 'GITHUB_APP_BRIDGE_REGRESSION_TESTS=FAIL'
    foreach ($failure in $failures) { Write-Output ('FAILED_CASE=' + $failure) }
    exit 1
}

Write-Output 'GITHUB_APP_BRIDGE_REGRESSION_TESTS=PASS'
Write-Output 'OLD_IMPLEMENTATION_REJECTED=PASS'
Write-Output 'DIRECT_WORKTREE_CASES=PASS'
