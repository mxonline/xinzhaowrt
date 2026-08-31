param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$Firmware,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$RouterPassword = 'password'
)

$ErrorActionPreference = 'Stop'

# This Stage M runner validates only the LuCI cgi-upload handoff. The production
# orchestrator performs standard sysupgrade after AUTO_FLASH_SAFETY_GATE.
function Invoke-TargetSsh {
    param([Parameter(Mandatory = $true)][string]$Command)
    $result = & ssh -o BatchMode=yes -o ConnectTimeout=8 $Target $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed: $Command`n$result"
    }
    return ($result -join "`n")
}

function Get-LuciUploadEndpoint {
    param([Parameter(Mandatory = $true)][string]$RouterIp)

    $pagePath = Join-Path $OutputDir 'luci-runtime-page.html'
    & curl.exe --silent --show-error --insecure --output $pagePath "https://$RouterIp/cgi-bin/luci/admin/system/flash"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read LuCI runtime page: curl exit $LASTEXITCODE"
    }

    $page = Get-Content -Raw -LiteralPath $pagePath
    $match = [regex]::Match($page, '"scriptname"\s*:\s*"(?<scriptname>[^"]+)"')
    if (-not $match.Success) {
        throw 'LuCI runtime page does not expose scriptname; refusing to guess CGI base.'
    }

    $scriptname = $match.Groups['scriptname'].Value.Replace('\/', '/')
    $cgiBase = $scriptname -replace '/[^/]+$', ''
    if ([string]::IsNullOrWhiteSpace($cgiBase) -or -not $cgiBase.StartsWith('/')) {
        throw "Invalid CGI base derived from LuCI scriptname: $scriptname"
    }

    return "$cgiBase/cgi-upload"
}

function Get-RouterSessionId {
    if ($RouterPassword.Contains("'")) {
        throw 'Router password containing a single quote is unsupported by this non-interactive safe shell invocation.'
    }
    $loginJson = @{ username = 'root'; password = $RouterPassword } | ConvertTo-Json -Compress
    $command = "ubus call session login '$loginJson' 2>/dev/null | jsonfilter -e '@.ubus_rpc_session'"
    $sessionId = (Invoke-TargetSsh $command).Trim()
    if ($sessionId -notmatch '^[0-9a-f]{32}$') {
        throw 'Unable to obtain a valid LuCI session id with existing SSH-authenticated router credentials.'
    }
    return $sessionId
}

function Invoke-LuciUpload {
    param(
        [Parameter(Mandatory = $true)][string]$RouterIp,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$LocalFile,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ResponsePath
    )

    $httpCode = & curl.exe --silent --show-error --insecure --output $ResponsePath --write-out '%{http_code}' `
        --form "sessionid=$SessionId" `
        --form "filename=$Destination" `
        --form "filedata=@$LocalFile" `
        "https://$RouterIp$Endpoint"
    if ($LASTEXITCODE -ne 0) {
        throw "LuCI upload transport failed: curl exit $LASTEXITCODE"
    }
    return ($httpCode -join '').Trim()
}

if ($Target -notmatch '^root@(?<ip>[0-9]{1,3}(?:\.[0-9]{1,3}){3})$') {
    throw 'Target must look like root@192.168.1.1'
}
if (-not (Test-Path -LiteralPath $Firmware)) {
    throw "Firmware is missing: $Firmware"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$RouterIp = $Matches['ip']
$expected = $ExpectedSha256.ToLowerInvariant()
$firmwareHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Firmware).Hash.ToLowerInvariant()
if ($firmwareHash -ne $expected) {
    throw "Firmware SHA256 mismatch: $firmwareHash"
}

$endpoint = Get-LuciUploadEndpoint -RouterIp $RouterIp
if ($endpoint -eq '/cgi-bin/luci/cgi-upload') {
    throw 'Derived endpoint is the legacy test-harness value; refusing to run.'
}

$nginxConfig = Invoke-TargetSsh 'nginx -T -c /etc/nginx/uci.conf 2>&1'
$nginxConfig | Set-Content -NoNewline -Encoding utf8 (Join-Path $OutputDir 'nginx-effective-config.txt')
if ($nginxConfig -notmatch [regex]::Escape($endpoint.Replace('/cgi-upload', '/cgi-')) -or $nginxConfig -notmatch 'luci-cgi_io\.socket') {
    throw "Nginx effective configuration does not prove $endpoint routes to luci-cgi_io.socket."
}

$sessionId = Get-RouterSessionId
$smallFile = Join-Path $OutputDir 'stage-m-small-preflight.txt'
Set-Content -NoNewline -Encoding ascii -LiteralPath $smallFile -Value 'xinzhaowrt-stage-m-small-upload'

$preflightResponse = Join-Path $OutputDir 'stage-m-small-preflight-response.json'
$preflightStatus = Invoke-LuciUpload -RouterIp $RouterIp -Endpoint $endpoint -SessionId $sessionId -LocalFile $smallFile -Destination '/tmp/firmware.bin' -ResponsePath $preflightResponse
if ($preflightStatus -notin @('200', '201')) {
    throw "Small upload preflight returned HTTP $preflightStatus"
}
$smallHash = Invoke-TargetSsh 'sha256sum /tmp/firmware.bin | awk ''{print $1}'''
$expectedSmallHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $smallFile).Hash.ToLowerInvariant()
if ($smallHash.Trim().ToLowerInvariant() -ne $expectedSmallHash) {
    throw 'Small upload preflight did not create the expected router file.'
}
Invoke-TargetSsh 'rm -f /tmp/firmware.bin; test ! -e /tmp/firmware.bin' | Out-Null
Write-Host 'SMALL_UPLOAD_PREFLIGHT=PASS'

$monitorPath = Join-Path $OutputDir 'large-upload-monitor.log'
$monitorCommand = 'date -Iseconds; free; grep -E ''MemAvailable|MemFree|Cached|SwapFree'' /proc/meminfo; df -h /tmp /root; ps w; dmesg | tail -n 80; logread -l 80'
$monitorJob = Start-Job -ScriptBlock {
    param($Target, $MonitorPath, $MonitorCommand)
    while ($true) {
        "=== $(Get-Date -Format o) ===" | Add-Content -Encoding utf8 $MonitorPath
        & ssh -o BatchMode=yes -o ConnectTimeout=8 $Target $MonitorCommand 2>&1 | Add-Content -Encoding utf8 $MonitorPath
        Start-Sleep -Seconds 1
    }
} -ArgumentList $Target, $monitorPath, $monitorCommand

try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $largeResponse = Join-Path $OutputDir 'large-upload-response.json'
    $largeStatus = Invoke-LuciUpload -RouterIp $RouterIp -Endpoint $endpoint -SessionId $sessionId -LocalFile $Firmware -Destination '/tmp/firmware.bin' -ResponsePath $largeResponse
    $stopwatch.Stop()
}
finally {
    Stop-Job -Job $monitorJob -ErrorAction SilentlyContinue | Out-Null
    Receive-Job -Job $monitorJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $monitorJob -Force -ErrorAction SilentlyContinue
}

if ($largeStatus -notin @('200', '201')) {
    throw "Large upload returned HTTP $largeStatus"
}
$remoteHash = (Invoke-TargetSsh 'sha256sum /tmp/firmware.bin | awk ''{print $1}''').Trim().ToLowerInvariant()
if ($remoteHash -ne $expected) {
    throw "Large upload SHA256 mismatch: $remoteHash"
}
Invoke-TargetSsh 'rm -f /tmp/firmware.bin; test ! -e /tmp/firmware.bin' | Out-Null

$postLogs = Invoke-TargetSsh 'dmesg; logread -l 500'
$postLogs | Set-Content -NoNewline -Encoding utf8 (Join-Path $OutputDir 'large-upload-post-logs.txt')
if ($postLogs -match '(?i)oom-killer|out of memory|kernel panic|watchdog.*reset|i/o error|input/output error|filesystem error|ext4-fs error') {
    throw 'Large upload produced a fatal kernel or storage log signature.'
}

@(
    "ACTUAL_UPLOAD_ENDPOINT=$endpoint"
    "UPLOAD_ENDPOINT_UPSTREAM=luci-cgi_io.socket"
    "HTTP_STATUS=$largeStatus"
    "UPLOAD_SECONDS=$([math]::Round($stopwatch.Elapsed.TotalSeconds, 3))"
    "FIRMWARE_SHA256=$remoteHash"
    'TEMP_FILE_CLEANUP=PASS'
    'LARGE_UPLOAD_OOM_REAL_DEVICE=PASS'
) | Set-Content -Encoding utf8 (Join-Path $OutputDir 'stage-m-summary.txt')

Write-Host 'LARGE_UPLOAD_OOM_REAL_DEVICE=PASS'
