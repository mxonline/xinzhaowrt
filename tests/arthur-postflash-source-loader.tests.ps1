$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot '.github\workflows\arthur-post-release-device-test.yml'
$workflowLines = @(Get-Content -LiteralPath $workflowPath)
$sourceStepStart = -1
for ($i = 0; $i -lt $workflowLines.Count; $i++) {
    if ([string]$workflowLines[$i] -eq '      - name: Load exact current workflow source') {
        $sourceStepStart = $i
        break
    }
}
if ($sourceStepStart -lt 0) { throw 'TEST_FAIL: the exact-source loader step is missing.' }

$runStart = -1
for ($i = $sourceStepStart; $i -lt $workflowLines.Count; $i++) {
    if ($i -gt $sourceStepStart -and [string]$workflowLines[$i] -match '^      - name:') { break }
    if ([string]$workflowLines[$i] -eq '        run: |') {
        $runStart = $i + 1
        break
    }
}
if ($runStart -lt 0) { throw 'TEST_FAIL: the exact-source loader must use a PowerShell run block.' }

$sourceScriptLines = @()
for ($i = $runStart; $i -lt $workflowLines.Count; $i++) {
    $line = [string]$workflowLines[$i]
    if ($line.Length -gt 0 -and $line -notmatch '^ {10}') { break }
    if ($line.Length -gt 0) { $sourceScriptLines += $line.Substring(10) } else { $sourceScriptLines += '' }
}
$sourceScriptText = $sourceScriptLines -join [Environment]::NewLine

# These assertions fail against the old loader before any workflow code changes.
foreach ($required in @(
    'WORKFLOW_SOURCE_LOCAL_REUSE=PASS',
    'SOURCE_FETCH_RETRY_CLASSIFICATION=PASS',
    "'cat-file','-e',`$commitSpec",
    "'worktree','add','--detach',`$sourceRoot,`$env:GITHUB_SHA",
    '$retryDelaysSeconds = @(5,10,20,30)',
    'SOURCE_FETCH_TRANSIENT_EXHAUSTED',
    'SOURCE_ORIGIN_MISMATCH',
    'SOURCE_COMMIT_MISMATCH',
    "Write-Output 'DEVICE_ACCESSED=NO'",
    "Write-Output 'SECOND_FLASH_EXECUTED=NO'",
    'SOURCE_FETCH_ATTEMPT attempt=$attempt/$maxAttempts'
)) {
    if (-not $sourceScriptText.Contains($required)) {
        throw "TEST_FAIL: PostFlash source loader is missing required local-first/retry behavior: $required"
    }
}

$tokens = $null
$parseErrors = $null
$sourceScriptPath = Join-Path ([IO.Path]::GetTempPath()) ("arthur-postflash-source-loader-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllLines($sourceScriptPath,$sourceScriptLines,[Text.UTF8Encoding]::new($false))
[void][Management.Automation.Language.Parser]::ParseFile($sourceScriptPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Remove-Item -Force -LiteralPath $sourceScriptPath
    throw "TEST_FAIL: source-loader PowerShell syntax is invalid: $(($parseErrors | ForEach-Object Message) -join '; ')"
}

$patternMatch = [regex]::Match($sourceScriptText, "(?m)^\s*\`$transientPattern\s*=\s*'(?<pattern>[^']+)'\s*$")
if (-not $patternMatch.Success) { throw 'TEST_FAIL: source-loader transient error pattern must be explicit.' }
$transientPattern = $patternMatch.Groups['pattern'].Value
foreach ($failureText in @(
    'curl 28 Operation too slow. Less than 1024 bytes/sec transferred the last 30 seconds',
    'fatal: early EOF',
    'fetch-pack: unexpected disconnect while reading sideband packet',
    'fatal: fetch-pack: invalid index-pack output',
    'curl 56 OpenSSL SSL_read: Connection was reset',
    'TLS handshake timeout',
    'connection reset by peer',
    'connection closed unexpectedly',
    'SSL connection has been closed',
    'remote end hung up unexpectedly',
    '远程方关闭传输流',
    '基础连接关闭'
)) {
    if ($failureText -notmatch $transientPattern) {
        throw "TEST_FAIL: a required transient fetch failure was not classified: $failureText"
    }
}

$gitCommand = Get-Command git.exe -ErrorAction Stop
$script:RealGitExe = $gitCommand.Source
function Invoke-TestGit {
    param([string[]]$Arguments)
    $output = @(& $script:RealGitExe @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "TEST_SETUP_FAIL: git exit=$code args=$($Arguments -join ' ') output=$(($output | ForEach-Object { [string]$_ }) -join ' ')"
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function New-TestRepository {
    param([string]$Path,[string]$Origin,[string]$FileName,[string]$Content)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $null = Invoke-TestGit @('-C',$Path,'init','--quiet')
    $null = Invoke-TestGit @('-C',$Path,'config','user.name','Arthur Source Loader Test')
    $null = Invoke-TestGit @('-C',$Path,'config','user.email','source-loader-test@example.invalid')
    $null = Invoke-TestGit @('-C',$Path,'remote','add','origin',$Origin)
    [IO.File]::WriteAllText((Join-Path $Path $FileName),$Content,[Text.UTF8Encoding]::new($false))
    $null = Invoke-TestGit @('-C',$Path,'add','--',$FileName)
    $null = Invoke-TestGit @('-C',$Path,'commit','--quiet','-m','source loader fixture')
    return (Invoke-TestGit @('-C',$Path,'rev-parse','HEAD'))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("als-{0}" -f [guid]::NewGuid().ToString('N').Substring(0,8))
$bareRemote = Join-Path $testRoot 'network-origin.git'
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$savedEnvironment = @{}
foreach ($name in @('LOCALAPPDATA','GITHUB_WORKSPACE','RUNNER_TEMP','GITHUB_ENV','GITHUB_REPOSITORY','GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
$savedGitFunction = Get-Item Function:\global:git -ErrorAction SilentlyContinue
$savedSleepFunction = Get-Item Function:\global:Start-Sleep -ErrorAction SilentlyContinue
$gitShim = {
    $argumentList = @($args | ForEach-Object { [string]$_ })
    $state = $global:ArthurSourceLoaderTestState
    $fetchIndex = [Array]::IndexOf($argumentList,'fetch')
    if ($fetchIndex -ge 0) {
        $state.FetchCount++
        if ($state.Mode -eq 'no-fetch') {
            $global:LASTEXITCODE = 97
            Write-Output 'TEST_UNEXPECTED_NETWORK_FETCH'
            return
        }
        if (($state.Mode -eq 'transient-once' -and $state.FetchCount -eq 1) -or $state.Mode -eq 'transient-always') {
            $global:LASTEXITCODE = 128
            Write-Output 'error: RPC failed; curl 28 Operation too slow. Less than 1024 bytes/sec transferred the last 30 seconds'
            Write-Output 'fetch-pack: unexpected disconnect while reading sideband packet'
            Write-Output 'fatal: early EOF'
            return
        }
        $originIndex = [Array]::IndexOf($argumentList,'origin')
        if ($originIndex -ge 0) { $argumentList[$originIndex] = $state.RemotePath }
        if ($state.Mode -eq 'identity-mismatch') { $argumentList[$argumentList.Count - 1] = $state.WrongSha }
    }
    $output = @(& $global:ArthurSourceLoaderTestGitExe @argumentList 2>&1)
    $code = $LASTEXITCODE
    foreach ($item in $output) { Write-Output ([string]$item) }
    $global:LASTEXITCODE = $code
}
$sleepShim = {
    param([int]$Seconds)
    $global:ArthurSourceLoaderTestState.SleepSeconds += $Seconds
}
Set-Item -Path Function:\global:git -Value $gitShim
Set-Item -Path Function:\global:Start-Sleep -Value $sleepShim
$global:ArthurSourceLoaderTestGitExe = $script:RealGitExe
$env:GIT_AUTHOR_NAME = 'Arthur Source Loader Test'
$env:GIT_AUTHOR_EMAIL = 'source-loader-test@example.invalid'
$env:GIT_COMMITTER_NAME = 'Arthur Source Loader Test'
$env:GIT_COMMITTER_EMAIL = 'source-loader-test@example.invalid'

function Invoke-LoaderScenario {
    param([string]$Name,[string]$Workspace,[string]$Sha,[string]$Mode,[string]$RemotePath,[string]$WrongSha)
    $runnerTemp = Join-Path $testRoot ("runner-{0}" -f $Name)
    New-Item -ItemType Directory -Force -Path $runnerTemp | Out-Null
    $envFile = Join-Path $runnerTemp 'github.env'
    [IO.File]::WriteAllText($envFile,'',[Text.UTF8Encoding]::new($false))
    $env:LOCALAPPDATA = Join-Path $testRoot ("localappdata-{0}" -f $Name)
    $env:GITHUB_WORKSPACE = $Workspace
    $env:RUNNER_TEMP = $runnerTemp
    $env:GITHUB_ENV = $envFile
    $env:GITHUB_REPOSITORY = 'mxonline/xinzhaowrt'
    $env:GITHUB_SHA = $Sha
    $env:GITHUB_RUN_ID = "source-loader-$Name"
    $env:GITHUB_RUN_ATTEMPT = '1'
    $global:ArthurSourceLoaderTestState = [pscustomobject]@{ Mode=$Mode; RemotePath=$RemotePath; WrongSha=$WrongSha; FetchCount=0; SleepSeconds=0 }
    $outputText = ''
    $errorText = ''
    try { $outputText = (& $sourceScriptPath 2>&1 | Out-String) }
    catch { $errorText = [string]$_; $outputText += [Environment]::NewLine + $errorText }
    $sourceRoot = Join-Path $runnerTemp ("arthur-post-release-source-source-loader-{0}-1" -f $Name)
    $sourceRepo = ''
    $envContents = if (Test-Path -LiteralPath $envFile) { [IO.File]::ReadAllText($envFile) } else { '' }
    $sourceRepoMatch = [regex]::Match($envContents,'(?m)^ARTHUR_SOURCE_REPO=(.*)$')
    if ($sourceRepoMatch.Success) { $sourceRepo = $sourceRepoMatch.Groups[1].Value.Trim() }
    return [pscustomobject]@{Name=$Name;Output=$outputText;Error=$errorText;SourceRoot=$sourceRoot;EnvFile=$envFile;FetchCount=$global:ArthurSourceLoaderTestState.FetchCount;SleepSeconds=$global:ArthurSourceLoaderTestState.SleepSeconds;Workspace=$Workspace;SourceRepo=$sourceRepo}
}

function Assert-LoadedSource {
    param($Scenario,[string]$ExpectedSha,[string]$ExpectedOrigin)
    if (-not $Scenario.Output.Contains('WORKFLOW_SOURCE=PASS commit=' + $ExpectedSha)) {
        throw "TEST_FAIL: $($Scenario.Name) did not pass exact source identity: $($Scenario.Output)"
    }
    $head = Invoke-TestGit @('-C',$Scenario.SourceRoot,'rev-parse','HEAD')
    if ($head -ne $ExpectedSha) { throw "TEST_FAIL: $($Scenario.Name) source HEAD mismatch: $head" }
    $origin = Invoke-TestGit @('-C',$Scenario.SourceRoot,'remote','get-url','origin')
    if ($origin -ne $ExpectedOrigin) { throw "TEST_FAIL: $($Scenario.Name) origin mismatch: $origin" }
    $dirty = Invoke-TestGit @('-C',$Scenario.SourceRoot,'status','--porcelain','--untracked-files=no')
    if (-not [string]::IsNullOrWhiteSpace($dirty)) { throw "TEST_FAIL: $($Scenario.Name) exact source tree is dirty: $dirty" }
}

function Remove-TestLoadedSource {
    param($Scenario)
    if ($Scenario -and (Test-Path -LiteralPath $Scenario.SourceRoot)) {
        if (Test-Path -LiteralPath (Join-Path $Scenario.SourceRoot '.git') -PathType Leaf) {
            $null = Invoke-TestGit @('-C',$Scenario.SourceRepo,'worktree','remove','--force',$Scenario.SourceRoot)
        }
        if (Test-Path -LiteralPath $Scenario.SourceRoot) { Remove-Item -Recurse -Force -LiteralPath $Scenario.SourceRoot }
    }
}

try {
    $expectedOrigin = 'https://github.com/mxonline/xinzhaowrt.git'
    $networkRepo = Join-Path $testRoot 'network-source'
    $targetSha = New-TestRepository -Path $networkRepo -Origin $expectedOrigin -FileName 'target.txt' -Content 'exact target commit'
    [IO.File]::WriteAllText((Join-Path $networkRepo 'wrong.txt'),'wrong fetched commit',[Text.UTF8Encoding]::new($false))
    $null = Invoke-TestGit @('-C',$networkRepo,'add','--','wrong.txt')
    $null = Invoke-TestGit @('-C',$networkRepo,'commit','--quiet','-m','wrong fetched commit')
    $wrongSha = Invoke-TestGit @('-C',$networkRepo,'rev-parse','HEAD')
    $null = Invoke-TestGit @('clone','--bare','--quiet',$networkRepo,$bareRemote)

    # CASE 3: exact local object is reused without any fetch.
    $localAppData = Join-Path $testRoot 'localappdata-local'
    $localRepo = Join-Path $localAppData 'XinZhaoWrt\ControlPlane\workspace'
    $localSha = New-TestRepository -Path $localRepo -Origin $expectedOrigin -FileName 'local.txt' -Content 'already cached exact commit'
    $emptyWorkspace = Join-Path $testRoot 'empty-github-workspace'
    New-Item -ItemType Directory -Force -Path $emptyWorkspace | Out-Null
    $local = Invoke-LoaderScenario -Name 'local' -Workspace $emptyWorkspace -Sha $localSha -Mode 'no-fetch' -RemotePath $bareRemote -WrongSha $wrongSha
    if ($local.FetchCount -ne 0 -or -not $local.Output.Contains('WORKFLOW_SOURCE_LOCAL_REUSE=PASS')) {
        throw "TEST_FAIL: exact local commit must use zero network fetches: $($local.Output)"
    }
    Assert-LoadedSource -Scenario $local -ExpectedSha $localSha -ExpectedOrigin $expectedOrigin
    Remove-TestLoadedSource $local

    # CASE 4: a transient curl 28 failure retries and then loads the exact commit.
    $fallbackRepo = Join-Path $testRoot 'network-fallback-candidate'
    $null = New-TestRepository -Path $fallbackRepo -Origin $expectedOrigin -FileName 'decoy.txt' -Content 'target absent from local object database'
    $fallback = Invoke-LoaderScenario -Name 'retry' -Workspace $fallbackRepo -Sha $targetSha -Mode 'transient-once' -RemotePath $bareRemote -WrongSha $wrongSha
    if ($fallback.FetchCount -ne 2 -or $fallback.SleepSeconds -ne 5 -or -not $fallback.Output.Contains('SOURCE_FETCH_RETRY attempt=1/4 delay_seconds=5')) {
        throw "TEST_FAIL: transient curl 28 must retry once and continue after backoff: $($fallback.Output)"
    }
    Assert-LoadedSource -Scenario $fallback -ExpectedSha $targetSha -ExpectedOrigin $expectedOrigin
    Remove-TestLoadedSource $fallback

    # A runner's GITHUB_WORKSPACE may be an unrelated checkout. Never reuse it,
    # but allow the canonical persistent repo miss to fall back to the pinned origin.
    $workspaceMismatchRoot = Join-Path $testRoot 'workspace-origin-mismatch'
    $workspaceMismatch = New-TestRepository -Path $workspaceMismatchRoot -Origin 'https://github.com/other/checkout.git' -FileName 'workspace.txt' -Content 'untrusted runner workspace'
    $persistentMissRoot = Join-Path $testRoot 'localappdata-ws-mismatch\XinZhaoWrt\ControlPlane\workspace'
    $null = New-TestRepository -Path $persistentMissRoot -Origin $expectedOrigin -FileName 'decoy.txt' -Content 'canonical repo without target commit'
    $workspaceFallback = Invoke-LoaderScenario -Name 'ws-mismatch' -Workspace $workspaceMismatchRoot -Sha $targetSha -Mode 'normal' -RemotePath $bareRemote -WrongSha $wrongSha
    if ($workspaceFallback.FetchCount -ne 1 -or
        -not $workspaceFallback.Output.Contains('SOURCE_LOCAL_CANDIDATE=ORIGIN_MISMATCH') -or
        -not $workspaceFallback.Output.Contains('WORKFLOW_SOURCE=PASS')) {
        throw "TEST_FAIL: an untrusted GITHUB_WORKSPACE should be skipped in favor of the exact pinned network source: $($workspaceFallback.Output)"
    }
    Assert-LoadedSource -Scenario $workspaceFallback -ExpectedSha $targetSha -ExpectedOrigin $expectedOrigin
    Remove-TestLoadedSource $workspaceFallback

    # Four bounded retries use the configured backoff and stop before device access.
    $exhaustionRepo = Join-Path $testRoot 'network-exhaustion-candidate'
    $null = New-TestRepository -Path $exhaustionRepo -Origin $expectedOrigin -FileName 'decoy.txt' -Content 'target absent locally'
    $exhaustion = Invoke-LoaderScenario -Name 'exhaustion' -Workspace $exhaustionRepo -Sha $targetSha -Mode 'transient-always' -RemotePath $bareRemote -WrongSha $wrongSha
    if ($exhaustion.FetchCount -ne 5 -or $exhaustion.SleepSeconds -ne 65 -or
        -not $exhaustion.Output.Contains('SOURCE_FETCH_TRANSIENT_EXHAUSTED attempts=5 retries=4') -or
        (Test-Path -LiteralPath $exhaustion.SourceRoot)) {
        throw "TEST_FAIL: exhausted transient fetches must stop after four retries, clean partial state and remain pre-device: fetches=$($exhaustion.FetchCount) sleep=$($exhaustion.SleepSeconds) root_exists=$(Test-Path -LiteralPath $exhaustion.SourceRoot) output=$($exhaustion.Output)"
    }

    # CASE 5a: a mismatched canonical persistent repo fails closed without network fallback.
    $badOriginRoot = Join-Path $testRoot 'localappdata-bad-origin\XinZhaoWrt\ControlPlane\workspace'
    $badOriginSha = New-TestRepository -Path $badOriginRoot -Origin 'https://github.com/other/repository.git' -FileName 'bad.txt' -Content 'untrusted persistent origin'
    $badOrigin = Invoke-LoaderScenario -Name 'bad-origin' -Workspace $emptyWorkspace -Sha $badOriginSha -Mode 'transient-once' -RemotePath $bareRemote -WrongSha $wrongSha
    if (-not $badOrigin.Output.Contains('SOURCE_ORIGIN_MISMATCH') -or $badOrigin.FetchCount -ne 0) {
        throw "TEST_FAIL: origin mismatch must fail closed before network fetch: $($badOrigin.Output)"
    }

    # CASE 5b: a successful fetch of a different commit fails closed and is not retried.
    $identityRepo = Join-Path $testRoot 'identity-mismatch-candidate'
    $null = New-TestRepository -Path $identityRepo -Origin $expectedOrigin -FileName 'decoy.txt' -Content 'target absent locally'
    $identity = Invoke-LoaderScenario -Name 'bad-identity' -Workspace $identityRepo -Sha $targetSha -Mode 'identity-mismatch' -RemotePath $bareRemote -WrongSha $wrongSha
    if (-not $identity.Output.Contains('SOURCE_COMMIT_MISMATCH') -or $identity.FetchCount -ne 1) {
        throw "TEST_FAIL: fetched SHA mismatch must fail closed without retry: $($identity.Output)"
    }
    Write-Output 'ARTHUR_SOURCE_LOADER_TRANSIENT_CLASSIFICATION=PASS'
    Write-Output 'ARTHUR_SOURCE_LOADER_LOCAL_REUSE_ZERO_FETCH=PASS'
    Write-Output 'ARTHUR_SOURCE_LOADER_TRANSIENT_RETRY=PASS'
    Write-Output 'ARTHUR_SOURCE_LOADER_BOUNDED_EXHAUSTION=PASS'
    Write-Output 'ARTHUR_SOURCE_LOADER_FAIL_CLOSED=PASS'
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')
    }
    if ($savedGitFunction) { Set-Item -Path Function:\global:git -Value $savedGitFunction.ScriptBlock }
    else { Remove-Item -Path Function:\global:git -ErrorAction SilentlyContinue }
    if ($savedSleepFunction) { Set-Item -Path Function:\global:Start-Sleep -Value $savedSleepFunction.ScriptBlock }
    else { Remove-Item -Path Function:\global:Start-Sleep -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $testRoot
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $sourceScriptPath
}
