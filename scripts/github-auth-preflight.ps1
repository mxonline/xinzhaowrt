[CmdletBinding()]
param(
    [ValidateSet('cancel', 'dispatch', 'release', 'workflow', 'read')]
    [string]$Operation = 'read',
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$CurrentRunId = '',
    [string]$CheckpointPath = '',
    [switch]$ProbeOnly,
    [switch]$Quiet,
    [switch]$Library
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AuthCheckpoint {
    param([string]$ExplicitPath)

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $paths = New-Object System.Collections.Generic.List[string]
    if ($ExplicitPath) { $paths.Add($ExplicitPath) }
    $paths.Add((Join-Path $repoRoot 'state\ci-v3-state.json'))
    $paths.Add((Join-Path $repoRoot 'output\headless-production\runtime-state.json'))

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            $run = 0L
            foreach ($property in @('run_id', 'github_run_id', 'candidate_id')) {
                if ($state.PSObject.Properties.Name -contains $property -and $state.$property) {
                    $run = [long]$state.$property
                    if ($run -gt 0) { break }
                }
            }
            if ($state.PSObject.Properties.Name -contains 'candidate' -and $state.candidate) {
                if ($state.candidate.PSObject.Properties.Name -contains 'github_run_id' -and $state.candidate.github_run_id) {
                    $run = [long]$state.candidate.github_run_id
                }
            }
            if ($state.PSObject.Properties.Name -contains 'observability' -and $state.observability) {
                if ($state.observability.PSObject.Properties.Name -contains 'github_run_id' -and $state.observability.github_run_id) {
                    $run = [long]$state.observability.github_run_id
                }
            }
            $stage = ''
            foreach ($property in @('phase', 'stage', 'current_stage')) {
                if ($state.PSObject.Properties.Name -contains $property -and $state.$property) {
                    $stage = [string]$state.$property
                    if ($stage) { break }
                }
            }
            if (-not $stage -and $state.PSObject.Properties.Name -contains 'observability' -and $state.observability) {
                $stage = [string]$state.observability.current_stage
            }
            return [pscustomobject]@{
                Path = $path
                Stage = $stage
                RunId = $run
                Status = if ($state.PSObject.Properties.Name -contains 'status') { [string]$state.status } else { '' }
            }
        }
        catch {
            continue
        }
    }
    return [pscustomobject]@{ Path = 'MISSING'; Stage = 'UNKNOWN'; RunId = 0L; Status = 'UNKNOWN' }
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-GitHubAppToken {
    param([string]$Repo)

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $configPath = Join-Path $repoRoot 'config\github-app.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }

    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $appId = [int]$config.github_app_id
        $installationId = [int]$config.installation_id
        $dpapiPath = [Environment]::ExpandEnvironmentVariables([string]$config.dpapi_path)
        if ($appId -le 0 -or $installationId -le 0 -or -not (Test-Path -LiteralPath $dpapiPath -PathType Leaf)) { return $null }

        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
        $protected = [IO.File]::ReadAllBytes($dpapiPath)
        $privateKeyBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $pemText = [Text.Encoding]::ASCII.GetString($privateKeyBytes)
        $derText = ($pemText -replace '-----BEGIN RSA PRIVATE KEY-----', '' -replace '-----END RSA PRIVATE KEY-----', '' -replace '\s', '')
        $privateKeyDer = [Convert]::FromBase64String($derText)
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $read = 0
        $rsa.ImportRSAPrivateKey($privateKeyDer, [ref]$read)

        $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ iat = $now - 60; exp = $now + 540; iss = $appId } -Compress)))
        $unsigned = [Text.Encoding]::ASCII.GetBytes("$header.$payload")
        $signature = $rsa.SignData($unsigned, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $jwt = "$header.$payload.$(ConvertTo-Base64Url $signature)"
        $headers = @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'XinZhaoWrt-Arthur-machine-credential'
            Authorization = "Bearer $jwt"
        }
        $app = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/app' -Headers $headers
        if ([int]$app.id -ne $appId) { return $null }
        $installation = Invoke-RestMethod -Method Get -Uri "https://api.github.com/app/installations/$installationId" -Headers $headers
        if ([int]$installation.id -ne $installationId -or [int]$installation.app_id -ne $appId) { return $null }
        $repositoryName = ($Repo -split '/')[-1]
        $body = @{ repositories = @($repositoryName) } | ConvertTo-Json -Compress
        $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://api.github.com/app/installations/$installationId/access_tokens" `
            -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $body
        $token = [string]$tokenResponse.token
        if ([string]::IsNullOrWhiteSpace($token)) { return $null }
        return $token
    }
    catch {
        return $null
    }
}

function Test-GitHubToken {
    param(
        [string]$Token,
        [string]$Repo,
        [string]$PreflightOperation,
        [string]$PreflightRunId
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $oldToken = $env:GH_TOKEN
    $env:GH_TOKEN = $Token
    try {
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            $login = (& gh api user --jq '.login' 2>$null | Out-String).Trim()
            if ($login -ne 'mxonline') { Start-Sleep -Seconds 1; continue }
            $fullName = (& gh api "repos/$Repo" --jq '.full_name' 2>$null | Out-String).Trim()
            if ($fullName -ne $Repo) { Start-Sleep -Seconds 1; continue }
            if ($PreflightOperation -eq 'cancel' -and $PreflightRunId -match '^[0-9]+$' -and [long]$PreflightRunId -gt 0) {
                $run = (& gh api "repos/$Repo/actions/runs/$PreflightRunId" --jq '.id' 2>$null | Out-String).Trim()
                if ($run -ne $PreflightRunId) { Start-Sleep -Seconds 1; continue }
            }
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -eq $oldToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $oldToken }
    }
}

function Set-GhKeyringToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $Token | & gh auth login --hostname github.com --with-token *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = 'Stop'
    }
}

function Write-AuthBlocker {
    param([string[]]$CheckedSources,[string]$CurrentRun)
    $checkpoint = Get-AuthCheckpoint -ExplicitPath $CheckpointPath
    $resolvedRun = if ($CurrentRun) { $CurrentRun } elseif ($checkpoint.RunId -gt 0) { [string]$checkpoint.RunId } else { 'UNKNOWN' }
    Write-Output 'AUTH_PREFLIGHT_GATE=BLOCKED'
    Write-Output 'AUTH_RECOVERY=BLOCKED_AUTH_CREDENTIAL_MISSING'
    Write-Output 'missing_credential=GitHub API credential for mxonline/xinzhaowrt'
    Write-Output ("checked_sources={0}" -f ($CheckedSources -join ','))
    Write-Output ("current_checkpoint={0};stage={1};status={2}" -f $checkpoint.Path, $checkpoint.Stage, $checkpoint.Status)
    Write-Output ("current_run_id={0}" -f $resolvedRun)
}

function Invoke-GitHubAuthPreflight {
    param(
        [ValidateSet('cancel', 'dispatch', 'release', 'workflow', 'read')]
        [string]$PreflightOperation = 'read',
        [string]$PreflightRepository = $Repository,
        [string]$PreflightRunId = $CurrentRunId,
        [switch]$PreflightProbeOnly,
        [switch]$PreflightQuiet
    )

    $checked = New-Object System.Collections.Generic.List[string]
    $candidates = New-Object System.Collections.Generic.List[object]
    $environmentSources = @{
        GH_TOKEN = 'GitHubActionsSecret/GH_TOKEN'
        GITHUB_TOKEN = 'GitHubActionsSecret/GITHUB_TOKEN'
        GITHUB_PAT = 'ExistingPAT/GITHUB_PAT'
        GH_PAT = 'ExistingPAT/GH_PAT'
        XINZHAO_GITHUB_TOKEN = 'ExistingPAT/XINZHAO_GITHUB_TOKEN'
    }
    foreach ($name in $environmentSources.Keys) {
        $checked.Add($environmentSources[$name])
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add([pscustomobject]@{ Source = $environmentSources[$name]; Token = $value }) }
    }

    $checked.Add('GitHubApp')
    $checked.Add('system credential store/keyring')
    $appToken = Get-GitHubAppToken -Repo $PreflightRepository
    if ($appToken) { $candidates.Add([pscustomobject]@{ Source = 'GitHubApp'; Token = $appToken }) }
    try {
        $keyringToken = (& gh auth token --hostname github.com 2>$null | Out-String).Trim()
        if ($keyringToken) { $candidates.Add([pscustomobject]@{ Source = 'system credential store/keyring'; Token = $keyringToken }) }
    }
    catch { }

    foreach ($candidate in $candidates) {
        if (-not (Test-GitHubToken -Token $candidate.Token -Repo $PreflightRepository `
                -PreflightOperation $PreflightOperation -PreflightRunId $PreflightRunId)) { continue }
        $env:GH_TOKEN = $candidate.Token
        if ($candidate.Source -eq 'GitHubApp' -and -not $PreflightProbeOnly) {
            [void](Set-GhKeyringToken -Token $candidate.Token)
        }
        if (-not $PreflightQuiet) {
            Write-Output 'AUTH_PREFLIGHT_GATE=PASS'
            Write-Output 'AUTH_RECOVERED=PASS'
            Write-Output 'AUTH_RECOVERY=AUTH_RECOVERED'
            Write-Output ("AUTH_SOURCE={0}" -f $candidate.Source)
            Write-Output ("AUTH_OPERATION={0}" -f $PreflightOperation)
        }
        return [pscustomobject]@{ Status = 'AUTH_RECOVERED'; Source = $candidate.Source; Token = $candidate.Token }
    }

    Write-AuthBlocker -CheckedSources $checked.ToArray() -CurrentRun $PreflightRunId
    return $null
}

if (-not $Library) {
    $result = @(Invoke-GitHubAuthPreflight -PreflightOperation $Operation -PreflightRepository $Repository `
        -PreflightRunId $CurrentRunId -PreflightProbeOnly:$ProbeOnly -PreflightQuiet:$true)
    $context = $result | Where-Object {
        if ($null -eq $_ -or $_ -is [string]) { return $false }
        $statusProperty = $_.PSObject.Properties['Status']
        $null -ne $statusProperty -and $statusProperty.Value -eq 'AUTH_RECOVERED'
    } | Select-Object -First 1
    if ($null -eq $context) {
        $result | ForEach-Object { Write-Output ([string]$_) }
        exit 78
    }
    if (-not $Quiet) {
        Write-Output 'AUTH_PREFLIGHT_GATE=PASS'
        Write-Output 'AUTH_RECOVERED=PASS'
        Write-Output 'AUTH_RECOVERY=AUTH_RECOVERED'
        Write-Output ("AUTH_SOURCE={0}" -f $context.Source)
        Write-Output ("AUTH_OPERATION={0}" -f $Operation)
    }
}
