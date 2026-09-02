param(
    [string]$Target = 'root@192.168.6.1',
    [string]$ExpectedVersion = '0.1.3',
    [string]$ExpectedBuildId = '33462873812'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HostPart = ($Target -split '@')[-1]
$BackupRoot = '/root/xinzhaowrt-runtime-backup'
$BackupDir = "$BackupRoot/$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
$RemoteView = '/www/luci-static/resources/view/adguardhome/config.js'
$RemoteAcl = '/usr/share/rpcd/acl.d/luci-app-adguardhome.json'
$LocalView = Join-Path $Root 'files\www\luci-static\resources\view\adguardhome\config.js'
$LocalAcl = Join-Path $Root 'files\usr\share\rpcd\acl.d\luci-app-adguardhome.json'
$TempView = '/tmp/xinzhao-adguard-config.js'
$TempAcl = '/tmp/xinzhao-adguard-acl.json'
$GateFileName = 'v013-prebuild-real-device-features.json'
$GatePath = if (-not [string]::IsNullOrWhiteSpace($env:ARTHUR_PREBUILD_GATE_PATH)) {
    $env:ARTHUR_PREBUILD_GATE_PATH
} elseif (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    Join-Path (Join-Path $env:ProgramData 'XinZhaoWrt') $GateFileName
} else {
    Join-Path (Join-Path $Root 'output\real-device') $GateFileName
}
$GateTempPath = "$GatePath.tmp"
$GateDirectory = Split-Path -Parent $GatePath
if (-not [string]::IsNullOrWhiteSpace($GateDirectory)) {
    New-Item -ItemType Directory -Force -Path $GateDirectory | Out-Null
}
Remove-Item -Force -ErrorAction SilentlyContinue $GatePath
Remove-Item -Force -ErrorAction SilentlyContinue $GateTempPath
$MutationStarted = $false
$OriginalAdguardConfigExists = $false
$OriginalViewExists = $false
$OriginalAclExists = $false

function Invoke-Remote {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$AllowFailure
    )
    $Command = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $Target $Command 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $text = ($raw -join "`n").Trim()
    if (-not $AllowFailure -and $exit -ne 0) {
        throw "REMOTE_COMMAND_FAILED exit=$exit command=$Command output=$text"
    }
    [pscustomobject]@{ ExitCode = $exit; Output = $text }
}

function Copy-ToRemote {
    param([Parameter(Mandatory=$true)][string]$Local,[Parameter(Mandatory=$true)][string]$Remote)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& scp.exe -O -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $Local "${Target}:$Remote" 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exit -ne 0) { throw "REMOTE_COPY_FAILED local=$Local remote=$Remote output=$(($raw -join "`n").Trim())" }
}

function Assert-RemoteOutput {
    param([Parameter(Mandatory=$true)][string]$Command,[Parameter(Mandatory=$true)][string]$Pattern,[Parameter(Mandatory=$true)][string]$Failure)
    $result = Invoke-Remote $Command
    if ($result.Output -notmatch $Pattern) { throw "$Failure output=$($result.Output)" }
    return $result.Output
}

function Restore-RuntimeBackup {
    if (-not $MutationStarted) { return }
    Write-Host "V013_LIVE_ROLLBACK_START backup=$BackupDir"
    $probe = Invoke-Remote 'echo ROLLBACK_SSH_OK' -AllowFailure
    if ($probe.ExitCode -ne 0) {
        Write-Warning 'Rollback could not start because the device is no longer reachable over the pre-validated control path.'
        return
    }

    $restore = @"
set -e
if [ -f '$BackupDir/adguardhome' ]; then cp '$BackupDir/adguardhome' /etc/config/adguardhome; fi
if [ ! -f '$BackupDir/adguardhome' ] && [ '$OriginalAdguardConfigExists' = 'False' ]; then rm -f /etc/config/adguardhome; fi
if [ -f '$BackupDir/luci' ]; then cp '$BackupDir/luci' /etc/config/luci; fi
if [ -f '$BackupDir/wireless' ]; then cp '$BackupDir/wireless' /etc/config/wireless; fi
if [ -f '$BackupDir/adguard-config.js' ]; then
  mkdir -p /www/luci-static/resources/view/adguardhome
  cp '$BackupDir/adguard-config.js' '$RemoteView'
elif [ '$OriginalViewExists' = 'False' ]; then
  rm -f '$RemoteView'
fi
if [ -f '$BackupDir/adguard-acl.json' ]; then
  mkdir -p /usr/share/rpcd/acl.d
  cp '$BackupDir/adguard-acl.json' '$RemoteAcl'
elif [ '$OriginalAclExists' = 'False' ]; then
  rm -f '$RemoteAcl'
fi
/etc/init.d/adguardhome stop >/dev/null 2>&1 || true
/etc/init.d/adguardhome disable >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
wifi reload >/dev/null 2>&1 || true
"@
    Invoke-Remote $restore -AllowFailure | Out-Null
    Write-Host 'V013_LIVE_ROLLBACK_DONE'
}

Assert-RemoteOutput 'echo XINZHAO_SSH_OK' '^XINZHAO_SSH_OK$' 'SSH_AUTH_FAILED' | Out-Null
$board = Assert-RemoteOutput 'ubus call system board' '(?i)jdcloud,re-ss-01|RE-SS-01' 'DEVICE_IDENTITY_MISMATCH'
$buildInfoRaw = Invoke-Remote 'cat /www/luci-static/xinzhao/build-info.json'
try { $buildInfo = $buildInfoRaw.Output | ConvertFrom-Json }
catch { throw "REAL_DEVICE_BUILD_INFO_INVALID $($_.Exception.Message)" }
$liveVersion = ([string]$buildInfo.Version).Trim()
$liveBuildId = ([string]$buildInfo.'Build ID').Trim()
if ($liveVersion -ne $ExpectedVersion) { throw "REAL_DEVICE_VERSION_MISMATCH expected=$ExpectedVersion actual=$liveVersion" }
if ($liveBuildId -ne $ExpectedBuildId) { throw "REAL_DEVICE_BUILD_MISMATCH expected=$ExpectedBuildId actual=$liveBuildId" }
Write-Host "V013_LIVE_BASELINE=PASS version=$liveVersion build_id=$liveBuildId"

$route = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq "$HostPart/32" -or $_.DestinationPrefix -eq '192.168.6.0/24' } |
    Sort-Object RouteMetric |
    Select-Object -First 1
if (-not $route) {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Sort-Object RouteMetric |
        Select-Object -First 1
}
$adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
$InterfaceAlias = [string]$adapter.Name
$wirelessRoute = ($InterfaceAlias -match '(?i)wi-?fi|wireless|wlan') -or ([string]$adapter.InterfaceDescription -match '(?i)wi-?fi|wireless|wlan|802\.11')
Write-Host "V013_CONTROL_PATH interface=$InterfaceAlias description=$($adapter.InterfaceDescription)"
if ($wirelessRoute) { throw "UNSAFE_WIFI_CONTROL_PATH interface=$InterfaceAlias; connect the Runner by Ethernet before applying Wi-Fi changes" }

if (-not (Test-Path $LocalView)) { throw "LOCAL_FEATURE_FILE_MISSING $LocalView" }
if (-not (Test-Path $LocalAcl)) { throw "LOCAL_FEATURE_FILE_MISSING $LocalAcl" }

try {
    $OriginalAdguardConfigExists = (Invoke-Remote "test -f '/etc/config/adguardhome'" -AllowFailure).ExitCode -eq 0
    $OriginalViewExists = (Invoke-Remote "test -f '$RemoteView'" -AllowFailure).ExitCode -eq 0
    $OriginalAclExists = (Invoke-Remote "test -f '$RemoteAcl'" -AllowFailure).ExitCode -eq 0
    $backup = @"
set -e
mkdir -p '$BackupDir'
if [ -f /etc/config/adguardhome ]; then cp /etc/config/adguardhome '$BackupDir/adguardhome'; fi
cp /etc/config/luci '$BackupDir/luci'
cp /etc/config/wireless '$BackupDir/wireless'
if [ -f '$RemoteView' ]; then cp '$RemoteView' '$BackupDir/adguard-config.js'; fi
if [ -f '$RemoteAcl' ]; then cp '$RemoteAcl' '$BackupDir/adguard-acl.json'; fi
"@
    Invoke-Remote $backup | Out-Null
    $MutationStarted = $true
    Write-Host "V013_LIVE_BACKUP=PASS path=$BackupDir"

    Copy-ToRemote $LocalView $TempView
    Copy-ToRemote $LocalAcl $TempAcl
    $install = @"
set -e
mkdir -p /www/luci-static/resources/view/adguardhome /usr/share/rpcd/acl.d
cp '$TempView' '$RemoteView'
cp '$TempAcl' '$RemoteAcl'
chmod 0644 '$RemoteView' '$RemoteAcl'
rm -f '$TempView' '$TempAcl'
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
"@
    Invoke-Remote $install | Out-Null

    Assert-RemoteOutput 'command -v AdGuardHome || command -v /usr/bin/AdGuardHome' 'AdGuardHome' 'ADGUARD_CORE_MISSING' | Out-Null
    Assert-RemoteOutput "test -f '$RemoteView' && test -f '$RemoteAcl' && echo ADGUARD_UI_FILES_OK" '^ADGUARD_UI_FILES_OK$' 'ADGUARD_UI_DEPLOY_FAILED' | Out-Null
    $cfg = Invoke-Remote 'test -f /etc/adguardhome/adguardhome.yaml && echo ADGUARD_CONFIG_PRESENT || true'
    if ($cfg.Output -match 'ADGUARD_CONFIG_PRESENT') {
        Invoke-Remote '/usr/bin/AdGuardHome --check-config --config /etc/adguardhome/adguardhome.yaml' | Out-Null
    }
    Invoke-Remote 'uci set adguardhome.config.enabled=1; uci commit adguardhome' | Out-Null
    Invoke-Remote '/etc/init.d/adguardhome start' | Out-Null
    Start-Sleep -Seconds 2
    $running = Invoke-Remote "pgrep -f '[A]dGuardHome' >/dev/null && echo ADGUARD_RUNNING || true"
    if ($running.Output -notmatch 'ADGUARD_RUNNING') { throw 'ADGUARD_START_VERIFY_FAILED' }
    Invoke-Remote '/etc/init.d/adguardhome stop' | Out-Null
    Invoke-Remote 'uci set adguardhome.config.enabled=0; uci commit adguardhome' | Out-Null
    Invoke-Remote '/etc/init.d/adguardhome disable' | Out-Null
    $stopped = Invoke-Remote "pgrep -f '[A]dGuardHome' >/dev/null && echo ADGUARD_STILL_RUNNING || echo ADGUARD_STOPPED"
    if ($stopped.Output -notmatch 'ADGUARD_STOPPED') { throw 'ADGUARD_STOP_VERIFY_FAILED' }
    Write-Host 'ADGUARD_LIVE=PASS final_state=stopped_disabled'

    Assert-RemoteOutput "(command -v quickstart >/dev/null 2>&1 || test -d /www/luci-static/quickstart || ubus -q list | grep -Eiq 'quickstart|istore|store') && echo QUICKSTART_PRESENT" '^QUICKSTART_PRESENT$' 'QUICKSTART_RUNTIME_MISSING' | Out-Null
    Invoke-Remote "uci set luci.main.homepage='admin/quickstart'; uci commit luci" | Out-Null
    Assert-RemoteOutput 'test "$(uci -q get luci.main.homepage)" = ''admin/quickstart'' && echo QUICKSTART_HOME_OK' '^QUICKSTART_HOME_OK$' 'QUICKSTART_HOME_VERIFY_FAILED' | Out-Null
    Write-Host 'QUICKSTART_LIVE=PASS homepage=admin/quickstart'

    $wifiApply = @'
set -e
count=0
for s in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
  d=$(uci -q get wireless.$s.device 2>/dev/null || true)
  b=$(uci -q get wireless.$d.band 2>/dev/null || true)
  case "$b" in
    2g|5g)
      uci set wireless.$s.ssid=xinzhaowrt
      uci set wireless.$s.key=12345678
      count=$((count+1))
      ;;
  esac
done
[ "$count" -ge 2 ]
uci commit wireless
wifi reload
'@
    Invoke-Remote $wifiApply | Out-Null
    Start-Sleep -Seconds 8
    Assert-RemoteOutput 'echo WIFI_RECONNECT_OK' '^WIFI_RECONNECT_OK$' 'WIFI_RELOAD_LOST_CONTROL_PATH' | Out-Null
    $wifiVerify = @'
set -e
count=0
for s in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
  d=$(uci -q get wireless.$s.device 2>/dev/null || true)
  b=$(uci -q get wireless.$d.band 2>/dev/null || true)
  case "$b" in
    2g|5g)
      [ "$(uci -q get wireless.$s.ssid)" = 'xinzhaowrt' ]
      [ "$(uci -q get wireless.$s.key)" = '12345678' ]
      count=$((count+1))
      ;;
  esac
done
[ "$count" -ge 2 ]
echo WIFI_RUNTIME_OK
'@
    Assert-RemoteOutput $wifiVerify '^WIFI_RUNTIME_OK$' 'WIFI_RUNTIME_VERIFY_FAILED' | Out-Null
    Write-Host 'WIFI_LIVE=PASS ssid=xinzhaowrt key=REDACTED'

    Assert-RemoteOutput "uci -q get network.lan.ipaddr" '^192\.168\.6\.1(/24)?$' 'LAN_REGRESSION' | Out-Null
    Assert-RemoteOutput 'test "$(uci -q get luci.main.homepage)" = ''admin/quickstart'' && echo HOME_OK' '^HOME_OK$' 'QUICKSTART_FINAL_REGRESSION' | Out-Null
    Assert-RemoteOutput 'test "$(uci -q get adguardhome.config.enabled)" = ''0'' && echo ADGUARD_UCI_DISABLED' '^ADGUARD_UCI_DISABLED$' 'ADGUARD_UCI_DEFAULT_STATE_REGRESSION' | Out-Null
    Assert-RemoteOutput '/etc/init.d/adguardhome enabled >/dev/null 2>&1 && echo ADGUARD_ENABLED || echo ADGUARD_DISABLED' '^ADGUARD_DISABLED$' 'ADGUARD_DEFAULT_STATE_REGRESSION' | Out-Null
    $stillStopped = Invoke-Remote "pgrep -f '[A]dGuardHome' >/dev/null && echo ADGUARD_RUNNING || echo ADGUARD_STOPPED"
    if ($stillStopped.Output -notmatch 'ADGUARD_STOPPED') { throw 'ADGUARD_FINAL_STATE_REGRESSION' }

    $gateMarkers = @(
        "V013_LIVE_BASELINE=PASS version=$liveVersion build_id=$liveBuildId",
        'ADGUARD_LIVE=PASS final_state=stopped_disabled',
        'QUICKSTART_LIVE=PASS homepage=admin/quickstart',
        'WIFI_LIVE=PASS ssid=xinzhaowrt key=REDACTED',
        'V013_PREBUILD_REAL_DEVICE_FEATURES=PASS'
    )
    Write-Host 'V013_PREBUILD_REAL_DEVICE_FEATURES=PASS'
    $gatePayload = [ordered]@{
        schema_version = '1.0'
        gate = 'V013_PREBUILD_REAL_DEVICE_FEATURES'
        status = 'PASS'
        baseline_version = $liveVersion
        baseline_build_id = $liveBuildId
        markers = $gateMarkers
        source = 'scripts/live-validate-v013-features.ps1'
        validated_at = [DateTime]::UtcNow.ToString('o')
    }
    $gateJson = $gatePayload | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($GateTempPath, $gateJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force $GateTempPath $GatePath
    Write-Host "V013_PREBUILD_GATE_DURABLE=PASS path=$GatePath"
}
catch {
    $message = $_.Exception.Message
    Write-Host "V013_PREBUILD_REAL_DEVICE_FEATURES=FAIL $message"
    Remove-Item -Force -ErrorAction SilentlyContinue $GatePath
    Remove-Item -Force -ErrorAction SilentlyContinue $GateTempPath
    Restore-RuntimeBackup
    throw
}
