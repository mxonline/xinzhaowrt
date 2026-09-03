[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$Git,
    [switch]$GitPush,
    [switch]$GitLsRemote,
    [switch]$GhDispatch,
    [switch]$GhProductionDispatch,
    [switch]$GhProductionRuns,
    [switch]$GhThemeDispatch,
    [switch]$GhThemeRuns,
    [switch]$GhRunWatch,
    [switch]$GhRunFailedLog,
    [switch]$GhRunStatus,
    [switch]$GhRunCancel,
    [switch]$GhRunJobs,
    [switch]$GhJobLog,
    [switch]$GhRunDownload,
    [switch]$GhRunArtifacts,
    [switch]$GhArtifactDownload,
    [switch]$GhArtifactDownloadCurl,
    [switch]$GhReleaseUploadCurl,
    [string]$Remote = 'origin',
    [string]$Refspec,
    [string]$RemoteRef,
    [string]$Workflow,
    [string]$Ref,
    [ValidateSet('rebuild_known_good','update_immortalwrt','update_feeds','update_plugins','update_all')]
    [string]$Mode = 'rebuild_known_good',
    [string]$SourceRef,
    [string]$Confirm,
    [string]$RunId,
    [string]$JobId,
    [string]$DownloadDir,
    [string]$ArtifactId,
    [string]$ReleaseTag,
    [string]$UploadFile,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$RunArgs
)

$ErrorActionPreference = 'Stop'
$appId = 4785980
$installationId = 158075076
$repository = 'mxonline/xinzhaowrt'
$configPath = Join-Path $PSScriptRoot '..\config\github-app.json'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$dpapiPath = [Environment]::ExpandEnvironmentVariables([string]$config.dpapi_path)

Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
$protected = [IO.File]::ReadAllBytes($dpapiPath)
$privateKeyBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$pemText = [Text.Encoding]::ASCII.GetString($privateKeyBytes)
$derText = ($pemText -replace '-----BEGIN RSA PRIVATE KEY-----', '' -replace '-----END RSA PRIVATE KEY-----', '' -replace '\s', '')
$privateKeyDer = [Convert]::FromBase64String($derText)
$rsa = [System.Security.Cryptography.RSA]::Create()
$read = 0
$rsa.ImportRSAPrivateKey($privateKeyDer, [ref]$read)

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ iat = $now - 60; exp = $now + 540; iss = [string]$appId } -Compress)))
$unsigned = [Text.Encoding]::ASCII.GetBytes("$header.$payload")
$signature = $rsa.SignData($unsigned, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$jwt = "$header.$payload.$(ConvertTo-Base64Url $signature)"
$headers = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'XinZhaoWrt-Arthur-machine-credential'
}
$bearerHeaders = $headers + @{ Authorization = "Bearer $jwt" }
if ($GhArtifactDownloadCurl) {
    $apiHeaders = @('-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', '-H', "Authorization: Bearer $jwt")
    $app = ((& curl.exe --fail --silent --show-error --retry 4 @apiHeaders 'https://api.github.com/app') | Out-String | ConvertFrom-Json)
    if ([int]$app.id -ne $appId) { throw 'GITHUB_APP_ID_MISMATCH' }
    $installation = ((& curl.exe --fail --silent --show-error --retry 4 @apiHeaders "https://api.github.com/app/installations/$installationId") | Out-String | ConvertFrom-Json)
    if ([int]$installation.id -ne $installationId -or [int]$installation.app_id -ne $appId) { throw 'GITHUB_INSTALLATION_MISMATCH' }
    $tokenJson = ((& curl.exe --fail --silent --show-error --retry 4 @apiHeaders -H 'Content-Type: application/json' -X POST --data '{"repositories":["xinzhaowrt"]}' "https://api.github.com/app/installations/$installationId/access_tokens") | Out-String | ConvertFrom-Json)
    $token = [string]$tokenJson.token
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'INSTALLATION_TOKEN_EMPTY' }
    if ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($DownloadDir)) { throw 'GH_ARTIFACT_DOWNLOAD_ARGUMENTS_REQUIRED' }
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $artifactPath = Join-Path $DownloadDir 'artifact.zip'
    & curl.exe --fail --location --retry 4 --continue-at - --output $artifactPath -H 'Accept: application/vnd.github+json' -H "Authorization: token $token" -H 'X-GitHub-Api-Version: 2022-11-28' "https://api.github.com/repos/$repository/actions/artifacts/$ArtifactId/zip"
    if ($LASTEXITCODE -ne 0) { throw "GH_ARTIFACT_DOWNLOAD_FAILED=$LASTEXITCODE" }
    Write-Output "ARTIFACT_DOWNLOAD=$ArtifactId"
    exit 0
}
$app = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/app' -Headers $bearerHeaders
if ([int]$app.id -ne $appId) { throw 'GITHUB_APP_ID_MISMATCH' }
$installation = Invoke-RestMethod -Method Get -Uri "https://api.github.com/app/installations/$installationId" -Headers $bearerHeaders
if ([int]$installation.id -ne $installationId -or [int]$installation.app_id -ne $appId) { throw 'GITHUB_INSTALLATION_MISMATCH' }
$tokenBody = @{ repositories = @('xinzhaowrt') } | ConvertTo-Json -Compress
$tokenResponse = Invoke-RestMethod -Method Post -Uri "https://api.github.com/app/installations/$installationId/access_tokens" -Headers ($headers + @{ Authorization = "Bearer $jwt"; 'Content-Type' = 'application/json' }) -Body $tokenBody
$token = [string]$tokenResponse.token
if ([string]::IsNullOrWhiteSpace($token)) { throw 'INSTALLATION_TOKEN_EMPTY' }
$repo = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repository" -Headers ($headers + @{ Authorization = "token $token" })
if ([string]$repo.full_name -ne $repository) { throw 'REPOSITORY_MISMATCH' }

if ($GhReleaseUploadCurl) {
    if ([string]::IsNullOrWhiteSpace($ReleaseTag) -or [string]::IsNullOrWhiteSpace($UploadFile)) { throw 'GH_RELEASE_UPLOAD_ARGUMENTS_REQUIRED' }
    if (-not (Test-Path -LiteralPath $UploadFile -PathType Leaf)) { throw 'GH_RELEASE_UPLOAD_FILE_MISSING' }
    $release = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repository/releases/tags/$ReleaseTag" -Headers ($headers + @{ Authorization = "token $token" })
    Write-Output "RELEASE_UPLOAD_API_URL=$([string]$release.upload_url)"
    $uploadBase = [string]$release.upload_url
    $templateIndex = $uploadBase.IndexOf('{')
    if ($templateIndex -ge 0) { $uploadBase = $uploadBase.Substring(0, $templateIndex) }
    $assetName = [uri]::EscapeDataString((Split-Path -Leaf $UploadFile))
    $uploadUri = '{0}?name={1}' -f $uploadBase, $assetName
    Write-Output "RELEASE_UPLOAD_URI=$uploadUri"
    & curl.exe --fail --location --retry 8 --retry-all-errors --retry-delay 5 --http1.1 --upload-file $UploadFile `
        -H 'Accept: application/vnd.github+json' -H "Authorization: token $token" -H 'X-GitHub-Api-Version: 2022-11-28' `
        -H 'Content-Type: application/octet-stream' $uploadUri
    if ($LASTEXITCODE -ne 0) { throw "GH_RELEASE_UPLOAD_FAILED=$LASTEXITCODE" }
    Write-Output "RELEASE_UPLOAD=$ReleaseTag"
    exit 0
}

if ($GhArtifactDownload) {
    if ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($DownloadDir)) { throw 'GH_ARTIFACT_DOWNLOAD_ARGUMENTS_REQUIRED' }
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    Invoke-WebRequest -Headers ($headers + @{ Authorization = "token $token" }) -Uri "https://api.github.com/repos/$repository/actions/artifacts/$ArtifactId/zip" -OutFile (Join-Path $DownloadDir 'artifact.zip')
    Write-Output "ARTIFACT_DOWNLOAD=$ArtifactId"
    exit 0
}
if ($GhArtifactDownloadCurl) {
    if ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($DownloadDir)) { throw 'GH_ARTIFACT_DOWNLOAD_ARGUMENTS_REQUIRED' }
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $artifactPath = Join-Path $DownloadDir 'artifact.zip'
    & curl.exe --fail --location --retry 3 --continue-at - --output $artifactPath -H "Accept: application/vnd.github+json" -H "Authorization: token $token" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/$repository/actions/artifacts/$ArtifactId/zip"
    if ($LASTEXITCODE -ne 0) { throw "GH_ARTIFACT_DOWNLOAD_FAILED=$LASTEXITCODE" }
    Write-Output "ARTIFACT_DOWNLOAD=$ArtifactId"
    exit 0
}

if ($Verify) {
    Write-Output 'AUTH_PROVIDER=GitHubApp'
    Write-Output 'AUTH_VALIDATION=PASS'
    Write-Output "APP_ID=$appId"
    Write-Output "INSTALLATION_ID=$installationId"
    Write-Output "REPOSITORY=$($repo.full_name)"
    exit 0
}

if ($GitPush) {
    if ([string]::IsNullOrWhiteSpace($Refspec)) { throw 'GIT_PUSH_REFSPEC_REQUIRED' }
    $RunArgs = @('git', '-c', 'credential.helper=', 'push', '-u', $Remote, $Refspec)
}
if ($GitLsRemote) {
    if ([string]::IsNullOrWhiteSpace($RemoteRef)) { throw 'GIT_LS_REMOTE_REF_REQUIRED' }
    $RunArgs = @('git', '-c', 'credential.helper=', 'ls-remote', $Remote, "refs/heads/$RemoteRef")
}
if ($GhDispatch) {
    if ([string]::IsNullOrWhiteSpace($Workflow) -or [string]::IsNullOrWhiteSpace($Ref) -or [string]::IsNullOrWhiteSpace($SourceRef)) { throw 'GH_DISPATCH_ARGUMENTS_REQUIRED' }
    $RunArgs = @('gh', 'workflow', 'run', $Workflow, '--repo', $repository, '--ref', $Ref, '-f', "source_ref=$SourceRef", '-f', 'publish_candidate=false')
}
if ($GhProductionDispatch) {
    if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'GH_PRODUCTION_DISPATCH_REF_REQUIRED' }
    $prebuildVerify = Join-Path $PSScriptRoot 'real-device-verify-v3.ps1'
    $prebuildGate = Join-Path $PSScriptRoot 'check-prebuild-real-device-gate.sh'
    $prebuildReport = Join-Path $PSScriptRoot '..\output\real-device\real-device-verification.json'
    if (-not (Test-Path -LiteralPath $prebuildVerify -PathType Leaf)) { throw 'PREBUILD_REAL_DEVICE_VERIFY_SCRIPT_MISSING' }
    if (-not (Test-Path -LiteralPath $prebuildGate -PathType Leaf)) { throw 'PREBUILD_REAL_DEVICE_GATE_SCRIPT_MISSING' }

    $localHead = ((& git -C (Join-Path $PSScriptRoot '..') rev-parse HEAD 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $localHead -notmatch '^[0-9a-f]{40}$') { throw 'PREBUILD_LOCAL_HEAD_UNAVAILABLE' }
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $prebuildReport

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $prebuildVerify -Commit $localHead -Target 'root@192.168.6.1' -Mode Prebuild
    if ($LASTEXITCODE -ne 0) { throw 'PREBUILD_REAL_DEVICE_VERIFY_FAILED' }
    if (-not (Test-Path -LiteralPath $prebuildReport -PathType Leaf)) { throw 'PREBUILD_REAL_DEVICE_EVIDENCE_MISSING_AFTER_VERIFY' }

    $bashCommand = Get-Command bash -ErrorAction SilentlyContinue
    $bashExecutable = if ($bashCommand) { $bashCommand.Source } else { $null }
    if (-not $bashExecutable) {
        $bashExecutable = @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $bashExecutable) { throw 'PREBUILD_REAL_DEVICE_GATE_BASH_MISSING' }
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Push-Location $repoRoot
    try {
        # Git Bash accepts repository-relative paths reliably on Windows; pass
        # relative paths instead of native C:\ paths that it may reinterpret.
        $gateProcess = Start-Process -FilePath $bashExecutable -ArgumentList @(
            'scripts/check-prebuild-real-device-gate.sh',
            'output/real-device/real-device-verification.json',
            $localHead
        ) -WorkingDirectory $repoRoot -Wait -PassThru -NoNewWindow
        $prebuildGateExit = $gateProcess.ExitCode
    }
    finally { Pop-Location }
    if ($prebuildGateExit -ne 0) { throw 'PREBUILD_REAL_DEVICE_GATE_FAILED' }

    $body = @{ ref = $Ref; inputs = @{ mode = $Mode } } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repository/actions/workflows/arthur-update-v3.yml/dispatches" -Headers ($headers + @{ Authorization = "token $token"; 'Content-Type' = 'application/json' }) -Body $body | Out-Null
    Write-Output "PREBUILD_REAL_DEVICE_VERIFY=PASS"
    Write-Output "PREBUILD_REAL_DEVICE_GATE=PASS"
    Write-Output "PREBUILD_SOURCE_SHA=$localHead"
    Write-Output "PRODUCTION_DISPATCHED=arthur-update-v3.yml"
    Write-Output "PRODUCTION_DISPATCH_REF=$Ref"
    Write-Output "PRODUCTION_DISPATCH_MODE=$Mode"
    exit 0
}
if ($GhProductionRuns) {
    if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'GH_PRODUCTION_RUNS_REF_REQUIRED' }
    $uri = "https://api.github.com/repos/$repository/actions/workflows/arthur-update-v3.yml/runs?branch=$([uri]::EscapeDataString($Ref))&event=workflow_dispatch&per_page=50"
    $runs = Invoke-RestMethod -Method Get -Uri $uri -Headers ($headers + @{ Authorization = "token $token" })
    $runs.workflow_runs | Select-Object id,status,conclusion,head_sha,head_branch,event,created_at,updated_at,html_url | ConvertTo-Json -Depth 5
    exit 0
}
if ($GhThemeDispatch) {
    if ([string]::IsNullOrWhiteSpace($Ref) -or [string]::IsNullOrWhiteSpace($Confirm)) { throw 'GH_THEME_DISPATCH_ARGUMENTS_REQUIRED' }
    if ($Confirm -ne 'BUILD_THEME_CANDIDATE') { throw 'GH_THEME_DISPATCH_CONFIRM_INVALID' }
    $RunArgs = @('gh', 'workflow', 'run', 'arthur-theme-candidate.yml', '--repo', $repository, '--ref', $Ref, '-f', "confirm=$Confirm")
}
if ($GhThemeRuns) {
    if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'GH_THEME_RUNS_REF_REQUIRED' }
    $RunArgs = @('gh', 'run', 'list', '--workflow', 'arthur-theme-candidate.yml', '--repo', $repository, '--branch', $Ref, '--limit', '10', '--json', 'databaseId,status,conclusion,headSha,event,url,displayTitle,createdAt')
}
if ($GhRunWatch) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'watch', $RunId, '--repo', $repository, '--exit-status')
}
if ($GhRunFailedLog) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'view', $RunId, '--repo', $repository, '--log-failed')
}
if ($GhRunStatus) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'view', $RunId, '--repo', $repository, '--json', 'status,conclusion,headSha,workflowName,url')
}
if ($GhRunCancel) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'cancel', $RunId, '--repo', $repository)
}
if ($GhRunJobs) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'view', $RunId, '--repo', $repository, '--json', 'jobs')
}
if ($GhJobLog) {
    if ([string]::IsNullOrWhiteSpace($JobId)) { throw 'GH_JOB_ID_REQUIRED' }
    $RunArgs = @('gh', 'run', 'view', '--job', $JobId, '--repo', $repository, '--log')
}
if ($GhRunDownload) {
    if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($DownloadDir)) { throw 'GH_RUN_DOWNLOAD_ARGUMENTS_REQUIRED' }
    $RunArgs = @('gh', 'run', 'download', $RunId, '--repo', $repository, '--dir', $DownloadDir)
}
if ($GhRunArtifacts) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'GH_RUN_ID_REQUIRED' }
    $RunArgs = @('gh', 'api', "repos/$repository/actions/runs/$RunId/artifacts", '--jq', '.artifacts[] | [.id,.name,.size_in_bytes,.expired] | @tsv')
}
if ($GhArtifactDownload) {
    if ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($DownloadDir)) { throw 'GH_ARTIFACT_DOWNLOAD_ARGUMENTS_REQUIRED' }
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $RunArgs = @('gh', 'api', "repos/$repository/actions/artifacts/$ArtifactId/zip", '--output', (Join-Path $DownloadDir 'artifact.zip'))
}
if (-not $RunArgs -or $RunArgs.Count -eq 0) {
    Write-Output 'AUTH_PROVIDER=GitHubApp'
    Write-Output 'AUTH_VALIDATION=PASS'
    exit 0
}

$env:GH_TOKEN = $token
$askPassPath = $null
try {
    if ($Git -or $GitPush -or $GitLsRemote) {
        $askPassPath = Join-Path ([IO.Path]::GetTempPath()) ("xinzhaowrt-git-askpass-" + [Guid]::NewGuid().ToString('N') + '.cmd')
        $askPassContent = '@echo off' + [Environment]::NewLine + 'echo %XINZAOWRT_GIT_TOKEN%'
        [IO.File]::WriteAllText($askPassPath, $askPassContent, [Text.Encoding]::ASCII)
        $env:XINZAOWRT_GIT_TOKEN = $token
        $env:GIT_ASKPASS = $askPassPath
        $env:GIT_TERMINAL_PROMPT = '0'
    }
    if ($RunArgs.Count -eq 1) {
        & $RunArgs[0]
    } else {
        & $RunArgs[0] $RunArgs[1..($RunArgs.Count - 1)]
    }
    exit $LASTEXITCODE
} finally {
    if ($askPassPath -and (Test-Path -LiteralPath $askPassPath)) { Remove-Item -LiteralPath $askPassPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:XINZAOWRT_GIT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_ASKPASS -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
}
