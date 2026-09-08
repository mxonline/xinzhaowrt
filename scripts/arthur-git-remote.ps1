Set-StrictMode -Version Latest

function Test-ArthurSchannelCredentialFailure {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)schannel.*(?:AcquireCredentialsHandle|acquire credentials|SEC_E_NO_CREDENTIALS)|SEC_E_NO_CREDENTIALS')
}

function Get-ArthurRemoteShaFromOutput {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $match = [regex]::Match($Text,'(?i)(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])')
    if (-not $match.Success) { return '' }
    return $match.Value.ToLowerInvariant()
}

function New-ArthurRemoteDecision {
    param(
        [Parameter(Mandatory=$true)][string]$Status,
        [Parameter(Mandatory=$true)][string]$Method,
        [bool]$Degraded=$false,
        [string]$RemoteSha='',
        [AllowNull()][string]$HumanGate=$null,
        [string]$Detail=''
    )
    return [pscustomobject][ordered]@{
        status = $Status
        method = $Method
        degraded = $Degraded
        remote_sha = $RemoteSha
        human_gate = $HumanGate
        detail = $Detail
    }
}

function Resolve-ArthurRemoteMainProbe {
    param(
        [Parameter(Mandatory=$true)]$Primary,
        $OpenSsl=$null,
        $Api=$null
    )

    $primarySha = if ([int]$Primary.ExitCode -eq 0) { Get-ArthurRemoteShaFromOutput ([string]$Primary.Output) } else { '' }
    if ([int]$Primary.ExitCode -eq 0 -and $primarySha) {
        return New-ArthurRemoteDecision -Status 'PASS' -Method 'GIT' -RemoteSha $primarySha
    }

    $primaryText = [string]$Primary.Output
    if (-not (Test-ArthurSchannelCredentialFailure $primaryText)) {
        return New-ArthurRemoteDecision -Status 'FAIL' -Method 'GIT' -Detail $primaryText
    }

    if ($null -ne $OpenSsl) {
        $openSslSha = if ([int]$OpenSsl.ExitCode -eq 0) { Get-ArthurRemoteShaFromOutput ([string]$OpenSsl.Output) } else { '' }
        if ([int]$OpenSsl.ExitCode -eq 0 -and $openSslSha) {
            return New-ArthurRemoteDecision -Status 'PASS' -Method 'GIT_OPENSSL' -Degraded $true -RemoteSha $openSslSha -Detail $primaryText
        }
    }

    if ($null -ne $Api) {
        $apiSha = if ([int]$Api.ExitCode -eq 0) { Get-ArthurRemoteShaFromOutput ([string]$Api.Output) } else { '' }
        if ([int]$Api.ExitCode -eq 0 -and $apiSha) {
            return New-ArthurRemoteDecision -Status 'PASS' -Method 'GH_API' -Degraded $true -RemoteSha $apiSha -Detail $primaryText
        }
    }

    return New-ArthurRemoteDecision -Status 'RETRYING' -Method 'SCHANNEL_FALLBACK_EXHAUSTED' -Degraded $true -Detail $primaryText
}

function Invoke-ArthurGitRemoteNative {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$UseOpenSsl
    )
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gitArgs = @('-c',"safe.directory=$Root")
        if ($UseOpenSsl) { $gitArgs += @('-c','http.sslBackend=openssl') }
        $gitArgs += @('-C',$Root)
        $gitArgs += $Arguments
        $output = (& git @gitArgs 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ ExitCode=$code; Output=$output }
}

function Invoke-ArthurGhRemoteNative {
    param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$Branch)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode=127; Output='gh unavailable' }
    }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $args = @('api',"repos/$Repository/git/ref/heads/$Branch",'--jq','.object.sha')
        $output = (& gh @args 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ ExitCode=$code; Output=$output }
}

function Get-ArthurRemoteMainHead {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$Repository='mxonline/xinzhaowrt',
        [string]$Branch='main'
    )
    $ref = "refs/heads/$Branch"
    $primary = Invoke-ArthurGitRemoteNative -Root $Root -Arguments @('ls-remote','--heads','origin',$ref)
    if ([int]$primary.ExitCode -eq 0) {
        return Resolve-ArthurRemoteMainProbe -Primary $primary
    }
    if (-not (Test-ArthurSchannelCredentialFailure ([string]$primary.Output))) {
        return Resolve-ArthurRemoteMainProbe -Primary $primary
    }
    $openssl = Invoke-ArthurGitRemoteNative -Root $Root -Arguments @('ls-remote','--heads','origin',$ref) -UseOpenSsl
    if ([int]$openssl.ExitCode -eq 0) {
        return Resolve-ArthurRemoteMainProbe -Primary $primary -OpenSsl $openssl
    }
    $api = Invoke-ArthurGhRemoteNative -Repository $Repository -Branch $Branch
    return Resolve-ArthurRemoteMainProbe -Primary $primary -OpenSsl $openssl -Api $api
}

function Invoke-ArthurGitFetchResilient {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$Repository='mxonline/xinzhaowrt',
        [string]$Branch='main'
    )
    $primary = Invoke-ArthurGitRemoteNative -Root $Root -Arguments @('fetch','--prune','origin',$Branch)
    if ([int]$primary.ExitCode -eq 0) {
        return [pscustomobject]@{ status='PASS'; method='GIT'; degraded=$false; human_gate=$null; output=[string]$primary.Output }
    }
    if (-not (Test-ArthurSchannelCredentialFailure ([string]$primary.Output))) {
        return [pscustomobject]@{ status='FAIL'; method='GIT'; degraded=$false; human_gate=$null; output=[string]$primary.Output }
    }

    $openssl = Invoke-ArthurGitRemoteNative -Root $Root -Arguments @('fetch','--prune','origin',$Branch) -UseOpenSsl
    if ([int]$openssl.ExitCode -eq 0) {
        return [pscustomobject]@{ status='PASS'; method='GIT_OPENSSL'; degraded=$true; human_gate=$null; output=[string]$openssl.Output }
    }

    $api = Invoke-ArthurGhRemoteNative -Repository $Repository -Branch $Branch
    $apiSha = if ([int]$api.ExitCode -eq 0) { Get-ArthurRemoteShaFromOutput ([string]$api.Output) } else { '' }
    $detail = "primary=$([string]$primary.Output); openssl=$([string]$openssl.Output); api=$([string]$api.Output)"
    if ($apiSha) {
        return [pscustomobject]@{ status='RETRYING'; method='GH_API_REACHABLE_FETCH_UNAVAILABLE'; degraded=$true; human_gate=$null; remote_sha=$apiSha; output=$detail }
    }
    return [pscustomobject]@{ status='RETRYING'; method='SCHANNEL_FALLBACK_EXHAUSTED'; degraded=$true; human_gate=$null; remote_sha=''; output=$detail }
}
