Set-StrictMode -Version Latest

function Get-ArthurVersionFromText {
    param([Parameter(Mandatory=$true)][string]$Text)
    $m = [regex]::Match($Text, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $m.Success) { return $null }
    return ('{0}.{1}.{2}' -f [int]$m.Groups[1].Value,[int]$m.Groups[2].Value,[int]$m.Groups[3].Value)
}

function Compare-ArthurVersion {
    param(
        [Parameter(Mandatory=$true)][string]$Left,
        [Parameter(Mandatory=$true)][string]$Right
    )
    $lv = Get-ArthurVersionFromText $Left
    $rv = Get-ArthurVersionFromText $Right
    if (-not $lv -or -not $rv) { throw "INVALID_ARTHUR_VERSION left='$Left' right='$Right'" }
    $la = @($lv.Split('.') | ForEach-Object { [int]$_ })
    $ra = @($rv.Split('.') | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt 3; $i++) {
        if ($la[$i] -lt $ra[$i]) { return -1 }
        if ($la[$i] -gt $ra[$i]) { return 1 }
    }
    return 0
}

function Test-ForwardCandidateVersion {
    param(
        [Parameter(Mandatory=$true)][string]$CandidateVersion,
        [Parameter(Mandatory=$true)][string]$BaselineVersion
    )
    return (Compare-ArthurVersion $CandidateVersion $BaselineVersion) -ge 0
}

function Test-ArthurVersionOperation {
    param(
        [Parameter(Mandatory=$true)][string]$CandidateVersion,
        [Parameter(Mandatory=$true)][string]$BaselineVersion,
        [ValidateSet('forward','rollback')][string]$Operation = 'forward'
    )
    if ($Operation -eq 'rollback') { return $true }
    return (Test-ForwardCandidateVersion -CandidateVersion $CandidateVersion -BaselineVersion $BaselineVersion)
}

function Test-ArthurBoardIdentity {
    param([string]$BoardOutput)
    if (-not $BoardOutput) { return $false }
    return ($BoardOutput -match '(?i)jdcloud,re-ss-01|JDCloud\s+RE-SS-01|RE-SS-01')
}

function Classify-ArthurSshProbe {
    param(
        [Parameter(Mandatory=$true)][int]$ExitCode,
        [string]$Output = ''
    )
    # Explicit changed/offending-key evidence is a hard identity mismatch.
    if ($Output -match '(?i)REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key|WARNING:.*HOST IDENTIFICATION HAS CHANGED') {
        return 'SSH_HOST_IDENTITY_MISMATCH'
    }
    # OpenSSH also emits the generic text below when a first-use key has not yet
    # been accepted. Treat that as untrusted/unenrolled, not as proof of change.
    if ($Output -match '(?i)Host key verification failed|No .* host key is known|The authenticity of host .* can.t be established') {
        return 'SSH_HOST_KEY_UNTRUSTED'
    }
    if ($ExitCode -eq 0) {
        if (Test-ArthurBoardIdentity -BoardOutput $Output) { return 'DEVICE_VERIFIED' }
        return 'DEVICE_IDENTITY_MISMATCH'
    }
    if ($Output -match '(?i)permission denied|authentication failed|too many authentication failures|no supported authentication methods|publickey,password') {
        return 'SSH_AUTH_FAILED'
    }
    if ($Output -match '(?i)connection timed out|operation timed out|connection refused|no route to host|network is unreachable|could not resolve hostname|connection reset|connection closed|actively refused') {
        return 'DEVICE_UNREACHABLE'
    }
    return 'DEVICE_UNREACHABLE'
}

function Test-ArthurBuildInfoMatchesBaseline {
    param(
        [Parameter(Mandatory=$true)]$BuildInfo,
        [Parameter(Mandatory=$true)]$Baseline
    )
    $version = Get-ArthurVersionFromText ([string]$BuildInfo.Version)
    if (-not $version -or $version -ne [string]$Baseline.firmware.version) { return $false }
    if ([string]$BuildInfo.'Build ID' -ne [string]$Baseline.firmware.build_id) { return $false }
    $observedCommit = ([string]$BuildInfo.'Git Commit').Trim().ToLowerInvariant()
    $expectedShort = ([string]$Baseline.firmware.displayed_git_commit).Trim().ToLowerInvariant()
    $expectedFull = ([string]$Baseline.firmware.source_sha).Trim().ToLowerInvariant()
    if (-not $observedCommit) { return $false }
    if ($observedCommit -ne $expectedShort -and -not $expectedFull.StartsWith($observedCommit)) { return $false }
    return $true
}
