param(
    [string]$Candidate = 'prebuild-current-router',

    [Parameter(Mandatory = $true)]
    [string]$Commit,

    [string]$Target = 'root@192.168.6.1',

    [string]$LuciCookieFile = $env:ARTHUR_LUCI_COOKIE_FILE,

    [ValidateSet('Prebuild','PostFlash')]
    [string]$Mode = 'Prebuild'
)

$ErrorActionPreference = 'Stop'

$BaseScript = Join-Path $PSScriptRoot 'real-device-verify.ps1'
if (-not (Test-Path $BaseScript)) {
    throw "Base real-device verification script is missing: $BaseScript"
}

if ($Mode -eq 'PostFlash' -and $Candidate -notmatch '^arthur-(known-good|update)-\d+$') {
    throw "PostFlash verification requires a real Candidate tag: $Candidate"
}
if ($Candidate -match '33462873812') {
    throw 'REJECTED_FOR_RELEASE: candidate 33462873812 is REAL_DEVICE_VERIFY_INVALIDATED and may not be reflashed or released.'
}

if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw "Commit must be a full 40-character Git SHA: $Commit"
}

if ($Target -notmatch '^[A-Za-z0-9._-]+@([0-9]{1,3}(?:\.[0-9]{1,3}){3})$') {
    throw "Target must look like root@192.168.6.1: $Target"
}

$HostIp = $Matches[1]
Write-Host "REAL_DEVICE_V3_TARGET=$Target"
Write-Host "REAL_DEVICE_V3_CANDIDATE=$Candidate"
Write-Host "REAL_DEVICE_V3_COMMIT=$Commit"
Write-Host "REAL_DEVICE_V3_MODE=$Mode"

& pwsh -NoProfile -ExecutionPolicy Bypass -File $BaseScript -DeviceIp $HostIp -Candidate $Candidate -Commit $Commit -LuciCookieFile $LuciCookieFile -Mode $Mode
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($Mode -eq 'PostFlash') {
    $AccessHelper = Join-Path $PSScriptRoot 'ensure-arthur-unattended-access.ps1'
    . $AccessHelper
    $Access = Ensure-ArthurUnattendedAccess -DeviceIp $HostIp

    $Ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $Ssh) { $Ssh = Get-Command ssh -ErrorAction Stop }
    $Args = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8')
    if ($Access.KnownHosts) { $Args += @('-o',"UserKnownHostsFile=$($Access.KnownHosts)") }
    $Args += @($Target, 'ubus call wireless status 2>/dev/null || true; iwinfo 2>/dev/null; uci -q show wireless')

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Raw = @(& $Ssh.Source @Args 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    $Output = (($Raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($Code -ne 0) { throw "POSTFLASH_WIFI_VERIFY=FAIL reason=read_only_probe_failed" }

    $wifi_2g = $Output -match '2\.4\d+ GHz'
    $wifi_5g = $Output -match '5\.\d+ GHz'
    $wifi_ssids = ([regex]::Matches($Output, '(?i)(?:ssid=|ESSID:\s*"?)xinzhaowrt')).Count -ge 2
    $wifi_password = ($Output -match '12345678') -and ($Output -notmatch '12356789')

    if (-not ($wifi_2g -and $wifi_5g -and $wifi_ssids -and $wifi_password)) {
        throw "POSTFLASH_WIFI_VERIFY=FAIL wifi_2g=$wifi_2g wifi_5g=$wifi_5g wifi_ssids=$wifi_ssids wifi_password=$wifi_password"
    }

    Write-Host 'POSTFLASH_WIFI_VERIFY=PASS wifi_2g=PASS wifi_5g=PASS wifi_ssids=PASS wifi_password=PASS'
}
