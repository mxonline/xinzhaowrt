param(
    [Parameter(Mandatory=$true)][string]$RequestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
$Status = Get-Content -Raw -LiteralPath (Join-Path $Root 'production\status.json') | ConvertFrom-Json

function Fail([string]$Code,[string]$Message) { throw "$Code $Message" }
function Require([bool]$Condition,[string]$Code,[string]$Message) { if (-not $Condition) { Fail $Code $Message } }

function Invoke-NativeCaptured {
    param([string]$FilePath,[string[]]$Arguments,[switch]$AllowFailure)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if (-not $AllowFailure -and $code -ne 0) { throw "NATIVE_COMMAND_FAILED file=$FilePath exit=$code output=$text" }
    [pscustomobject]@{ ExitCode=$code; Output=$text }
}

function Invoke-StrictSsh {
    param([string]$KnownHosts,[string]$Command,[switch]$AllowFailure)
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { $ssh = Get-Command ssh -ErrorAction Stop }
    $args = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$KnownHosts",'-o','ConnectTimeout=10','root@192.168.6.1',$Command)
    Invoke-NativeCaptured -FilePath $ssh.Source -Arguments $args -AllowFailure:$AllowFailure
}

function Invoke-StrictScp {
    param([string]$KnownHosts,[string]$LocalPath,[string]$RemotePath)
    $scp = Get-Command scp.exe -ErrorAction SilentlyContinue
    if (-not $scp) { $scp = Get-Command scp -ErrorAction Stop }
    $args = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$KnownHosts",'-o','ConnectTimeout=15',$LocalPath,("root@192.168.6.1:" + $RemotePath))
    Invoke-NativeCaptured -FilePath $scp.Source -Arguments $args
}

function Write-JsonFile([string]$Path,$Object) {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Object | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function New-RootLuciCookie {
    param([string]$KnownHosts)
    $create = Invoke-StrictSsh -KnownHosts $KnownHosts -Command 'ubus call session create'
    try { $obj = $create.Output | ConvertFrom-Json } catch { Fail 'LUCI_SESSION_CREATE_INVALID_JSON' $create.Output }
    $sid = [string]$obj.ubus_rpc_session
    Require (-not [string]::IsNullOrWhiteSpace($sid)) 'LUCI_SESSION_ID_MISSING' 'ubus did not return a session id'
    $token = [Guid]::NewGuid().ToString('N')
    $setPayload = @{ ubus_rpc_session=$sid; values=@{username='root';token=$token} } | ConvertTo-Json -Compress
    $ubusPayload = @{ ubus_rpc_session=$sid; scope='ubus'; objects=@(@('*','*')) } | ConvertTo-Json -Compress
    $filePayload = @{ ubus_rpc_session=$sid; scope='file'; objects=@(@('*','*')) } | ConvertTo-Json -Compress
    foreach ($entry in @(
        "ubus call session set '$setPayload'",
        "ubus call session grant '$ubusPayload'",
        "ubus call session grant '$filePayload'"
    )) {
        $r = Invoke-StrictSsh -KnownHosts $KnownHosts -Command $entry -AllowFailure
        Require ($r.ExitCode -eq 0) 'LUCI_SESSION_GRANT_FAILED' $r.Output
    }
    $cookie = Join-Path $env:RUNNER_TEMP ("arthur-v016-luci-{0}.cookie" -f [Guid]::NewGuid().ToString('N'))
    $tab = [char]9
    $cookieLine = "192.168.6.1" + $tab + "FALSE" + $tab + "/" + $tab + "FALSE" + $tab + "0" + $tab + "sysauth_http" + $tab + $sid
    @('# Netscape HTTP Cookie File',$cookieLine) | Set-Content -Encoding ASCII -LiteralPath $cookie
    [pscustomobject]@{ Cookie=$cookie; Session=$sid }
}

function Invoke-LuciGet {
    param([string]$Cookie,[string]$Path)
    $body = Join-Path $env:RUNNER_TEMP ("luci-body-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $url = "http://192.168.6.1$Path"
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    $r = Invoke-NativeCaptured -FilePath $curl -Arguments @('-sS','-L','--max-time','25','-b',$Cookie,'-o',$body,'-w','%{http_code}',$url) -AllowFailure
    $content = if (Test-Path -LiteralPath $body) { Get-Content -Raw -LiteralPath $body } else { '' }
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $body
    [pscustomobject]@{ ExitCode=$r.ExitCode; HttpCode=$r.Output.Trim(); Body=$content; Url=$url }
}

Require ([int]$Request.schema_version -eq 1) 'REQUEST_SCHEMA_INVALID' 'schema_version must be 1'
Require ([string]$Request.status -eq 'AUTHORIZED') 'POST_RELEASE_TEST_NOT_AUTHORIZED' 'request status must be AUTHORIZED'
Require ($Request.device_write_authorized -eq $true) 'DEVICE_WRITE_NOT_AUTHORIZED' 'exact post-release device write authorization is required'
Require ($Request.clean_flash_authorized -eq $true) 'CLEAN_FLASH_NOT_AUTHORIZED' 'clean flash authorization is required'
Require ([string]$Request.authorization_scope -eq 'POST_RELEASE_DEVICE_TEST_ONLY') 'AUTHORIZATION_SCOPE_INVALID' 'authorization must be post-release-only'
Require ([string]$Request.release_tag -eq 'v0.1.6') 'RELEASE_IDENTITY_MISMATCH' 'request release_tag must be v0.1.6'
Require ([string]$Request.candidate_tag -eq 'arthur-update-38000704263') 'CANDIDATE_IDENTITY_MISMATCH' 'unexpected Candidate tag'
Require ([long]$Request.build_run_id -eq 38000704263) 'BUILD_IDENTITY_MISMATCH' 'unexpected build run'
Require ([long]$Request.artifact_id -eq 11655711894) 'ARTIFACT_IDENTITY_MISMATCH' 'unexpected artifact id'
Require ([string]$Request.source_sha -eq 'b4448e62ab1e767f9a60221b0600c60c355baf56') 'SOURCE_IDENTITY_MISMATCH' 'unexpected source sha'
Require ([string]$Request.sysupgrade_sha256 -eq 'e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39') 'FIRMWARE_HASH_IDENTITY_MISMATCH' 'unexpected sysupgrade hash'
Require ([string]$Request.rollback_tag -eq 'arthur-production-36348777394') 'ROLLBACK_IDENTITY_MISMATCH' 'unexpected rollback tag'
Require ([string]$Request.rollback_sha256 -eq '97c7860df005e3d222d64f91872933c65ce5c77f4063ec641764f1013cf504e4') 'ROLLBACK_HASH_IDENTITY_MISMATCH' 'unexpected rollback hash'

Require ([string]$Status.status -eq 'PRODUCTION_RELEASED') 'RELEASE_STATE_INVALID' 'v0.1.6 must already be PRODUCTION_RELEASED'
Require ([string]$Status.version -eq 'v0.1.6') 'RELEASE_STATE_INVALID' 'status version mismatch'
Require ([long]$Status.run_id -eq [long]$Request.build_run_id) 'RELEASE_STATE_INVALID' 'status run mismatch'
Require ([long]$Status.artifact_id -eq [long]$Request.artifact_id) 'RELEASE_STATE_INVALID' 'status artifact mismatch'
Require ([string]$Status.source_commit -eq [string]$Request.source_sha) 'RELEASE_STATE_INVALID' 'status source mismatch'
Require ([string]$Status.sysupgrade_sha256 -eq [string]$Request.sysupgrade_sha256) 'RELEASE_STATE_INVALID' 'status sysupgrade hash mismatch'
Require ([string]$Status.post_release_device_test -eq 'PENDING_INDEPENDENT') 'POST_RELEASE_STATE_INVALID' 'post-release test is not pending'

$gh = (Get-Command gh -ErrorAction Stop).Source
$repo = 'mxonline/xinzhaowrt'
$releaseJson = (Invoke-NativeCaptured -FilePath $gh -Arguments @('release','view',$Request.release_tag,'--repo',$repo,'--json','tagName,targetCommitish,isDraft,isPrerelease,id')).Output | ConvertFrom-Json
$candidateJson = (Invoke-NativeCaptured -FilePath $gh -Arguments @('release','view',$Request.candidate_tag,'--repo',$repo,'--json','tagName,targetCommitish,isDraft,isPrerelease,id')).Output | ConvertFrom-Json
Require (-not $releaseJson.isDraft -and -not $releaseJson.isPrerelease) 'STABLE_RELEASE_IDENTITY_INVALID' 'v0.1.6 is not a final release'
Require ([string]$releaseJson.targetCommitish -eq [string]$Request.source_sha) 'STABLE_RELEASE_IDENTITY_INVALID' 'stable target source mismatch'
Require ($candidateJson.isPrerelease -eq $true) 'CANDIDATE_RELEASE_IDENTITY_INVALID' 'candidate is not a prerelease'
Require ([string]$candidateJson.targetCommitish -eq [string]$Request.source_sha) 'CANDIDATE_RELEASE_IDENTITY_INVALID' 'candidate target source mismatch'
$runJson = (Invoke-NativeCaptured -FilePath $gh -Arguments @('api',"repos/$repo/actions/runs/$($Request.build_run_id)")).Output | ConvertFrom-Json
Require ([string]$runJson.status -eq 'completed' -and [string]$runJson.conclusion -eq 'success') 'BUILD_RUN_NOT_SUCCESSFUL' 'build run is not completed/success'
$artifactJson = (Invoke-NativeCaptured -FilePath $gh -Arguments @('api',"repos/$repo/actions/artifacts/$($Request.artifact_id)")).Output | ConvertFrom-Json
Require ([string]$artifactJson.digest -eq [string]$Request.actions_artifact_sha256) 'ACTIONS_ARTIFACT_DIGEST_MISMATCH' 'actions artifact digest mismatch'

$work = Join-Path $env:RUNNER_TEMP 'arthur-v016-post-release'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
$stableDir = Join-Path $work 'stable'
$candidateDir = Join-Path $work 'candidate'
$rollbackDir = Join-Path $work 'rollback'
New-Item -ItemType Directory -Force -Path $stableDir,$candidateDir,$rollbackDir | Out-Null
$firmwareName = 'XinZhaoWrt-Arthur-v0.1.6-20261009-sysupgrade.bin'
$rollbackName = 'XinZhaoWrt-Arthur-v0.1.5-20260927-sysupgrade.bin'
Invoke-NativeCaptured -FilePath $gh -Arguments @('release','download',$Request.release_tag,'--repo',$repo,'--dir',$stableDir,'--clobber','--pattern',$firmwareName) | Out-Null
Invoke-NativeCaptured -FilePath $gh -Arguments @('release','download',$Request.candidate_tag,'--repo',$repo,'--dir',$candidateDir,'--clobber','--pattern',$firmwareName) | Out-Null
Invoke-NativeCaptured -FilePath $gh -Arguments @('release','download',$Request.rollback_tag,'--repo',$repo,'--dir',$rollbackDir,'--clobber','--pattern',$rollbackName) | Out-Null
$stableFirmware = Join-Path $stableDir $firmwareName
$candidateFirmware = Join-Path $candidateDir $firmwareName
$rollbackFirmware = Join-Path $rollbackDir $rollbackName
Require (Test-Path $stableFirmware) 'STABLE_ASSET_MISSING' $firmwareName
Require (Test-Path $candidateFirmware) 'CANDIDATE_ASSET_MISSING' $firmwareName
Require (Test-Path $rollbackFirmware) 'ROLLBACK_ASSET_MISSING' $rollbackName
$stableHash = (Get-FileHash -Algorithm SHA256 $stableFirmware).Hash.ToLowerInvariant()
$candidateHash = (Get-FileHash -Algorithm SHA256 $candidateFirmware).Hash.ToLowerInvariant()
$rollbackHash = (Get-FileHash -Algorithm SHA256 $rollbackFirmware).Hash.ToLowerInvariant()
Require ($stableHash -eq [string]$Request.sysupgrade_sha256) 'STABLE_RELEASE_HASH_MISMATCH' 'stable release sysupgrade SHA256 mismatch'
Require ($candidateHash -eq $stableHash) 'CANDIDATE_STABLE_BYTES_MISMATCH' 'candidate and stable sysupgrade bytes differ'
Require ($rollbackHash -eq [string]$Request.rollback_sha256) 'ROLLBACK_HASH_MISMATCH' 'verified rollback SHA256 mismatch'
Write-Host "EXACT_RELEASE_BYTES=PASS sha256=$stableHash"
Write-Host 'CANDIDATE_TO_STABLE_IDENTICAL_BYTES=PASS'
Write-Host "ROLLBACK_AVAILABLE=PASS sha256=$rollbackHash"

. (Join-Path $Root 'scripts\ensure-arthur-unattended-access.ps1')
$access = Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1'
$knownHosts = [string]$access.KnownHosts
$policy = Get-ArthurAccessPolicy
$beforeBuild = Get-ArthurHttpBuildInfo -DeviceIp '192.168.6.1' -Policy $policy
$beforeFields = Get-ArthurBuildIdentityFields -Build $beforeBuild
$beforeBoard = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'ubus call system board; cat /sys/class/net/br-lan/address'
Require ($beforeBoard.ExitCode -eq 0 -and $beforeBoard.Output -match 'jdcloud,re-ss-01') 'DEVICE_IDENTITY_MISMATCH' 'Arthur board identity mismatch before write'

$persistDir = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\PostReleaseDeviceTest\v0.1.6-38000704263'
$persistState = Join-Path $persistDir 'state.json'
New-Item -ItemType Directory -Force -Path $persistDir | Out-Null
$state = $null
if (Test-Path $persistState) {
    try { $state = Get-Content -Raw -LiteralPath $persistState | ConvertFrom-Json } catch { Fail 'PERSISTENT_FLASH_STATE_INVALID' 'cannot parse persistent at-most-once state' }
}
$alreadyExact = ([string]$beforeFields.Version -eq '0.1.6' -and [string]$beforeFields.BuildId -eq '38000704263')
if ($alreadyExact) {
    Write-Host 'FLASH_RECONCILE=EXACT_RELEASE_ALREADY_RUNNING'
}
else {
    if ($state -and [string]$state.flash_state -in @('FLASH_STARTED','WAIT_DEVICE')) { Fail 'AMBIGUOUS_FLASH_STATE' 'Prior flash may have started; refusing a second write until device identity is reconciled.' }
    Require ([string]$beforeFields.Version -eq '0.1.5' -and [string]$beforeFields.BuildId -eq '36764137044') 'UNEXPECTED_PREFLASH_BASELINE' "version=$($beforeFields.Version) build=$($beforeFields.BuildId)"
    $df = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'df -Pk /tmp | tail -n 1'
    $parts = @($df.Output -split '\s+' | Where-Object { $_ })
    Require ($parts.Count -ge 6) 'TMP_CAPACITY_UNKNOWN' $df.Output
    $availableKb = [long]$parts[3]
    $requiredKb = [long][Math]::Ceiling((Get-Item $stableFirmware).Length / 1024.0) + 32768
    Require ($availableKb -gt $requiredKb) 'TMP_CAPACITY_INSUFFICIENT' "available_kb=$availableKb required_kb=$requiredKb"
    $remote = '/tmp/XinZhaoWrt-Arthur-v0.1.6-post-release-sysupgrade.bin'
    Invoke-StrictScp -KnownHosts $knownHosts -LocalPath $stableFirmware -RemotePath $remote | Out-Null
    $remoteHash = Invoke-StrictSsh -KnownHosts $knownHosts -Command "sha256sum '$remote'"
    Require ($remoteHash.Output -match '^([0-9a-fA-F]{64})') 'REMOTE_HASH_UNAVAILABLE' $remoteHash.Output
    Require ($Matches[1].ToLowerInvariant() -eq $stableHash) 'REMOTE_HASH_MISMATCH' 'remote candidate bytes differ'
    $test = Invoke-StrictSsh -KnownHosts $knownHosts -Command "/sbin/sysupgrade -T '$remote'" -AllowFailure
    Require ($test.ExitCode -eq 0) 'SYSUPGRADE_TEST_FAILED' $test.Output
    Write-Host 'SYSUPGRADE_TEST=PASS'
    $state = [ordered]@{schema_version=1;release_tag=[string]$Request.release_tag;candidate_tag=[string]$Request.candidate_tag;source_sha=[string]$Request.source_sha;build_run_id=[long]$Request.build_run_id;sysupgrade_sha256=$stableHash;rollback_tag=[string]$Request.rollback_tag;rollback_sha256=$rollbackHash;flash_state='FLASH_STARTED';flash_started_at=[DateTimeOffset]::UtcNow.ToString('o');at_most_once=$true}
    Write-JsonFile $persistState $state
    Write-Host 'CLEAN_FLASH_AT_MOST_ONCE=ARMED'
    Write-Host 'FLASH_STARTED=YES method=standard-sysupgrade-n'
    $flash = Invoke-StrictSsh -KnownHosts $knownHosts -Command "sync; /sbin/sysupgrade -n '$remote'" -AllowFailure
    $state.flash_state = 'WAIT_DEVICE'
    $state.flash_command_exit = $flash.ExitCode
    Write-JsonFile $persistState $state
    Start-Sleep -Seconds 35
    $deadline = (Get-Date).AddMinutes(10)
    $online = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $probe = Invoke-WebRequest -UseBasicParsing -Uri 'http://192.168.6.1/luci-static/xinzhao/build-info.json' -TimeoutSec 5
            if ($probe.StatusCode -eq 200) { $online = $true; break }
        }
        catch {}
        Start-Sleep -Seconds 8
    }
    Require $online 'DEVICE_DID_NOT_RETURN' 'Arthur did not return after clean flash'
    $access = Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1'
    $knownHosts = [string]$access.KnownHosts
    $afterBuild = Get-ArthurHttpBuildInfo -DeviceIp '192.168.6.1' -Policy $policy
    $afterFields = Get-ArthurBuildIdentityFields -Build $afterBuild
    Require ([string]$afterFields.Version -eq '0.1.6') 'POSTFLASH_RELEASE_IDENTITY_MISMATCH' "version=$($afterFields.Version)"
    Require ([string]$afterFields.BuildId -eq '38000704263') 'POSTFLASH_BUILD_IDENTITY_MISMATCH' "build_id=$($afterFields.BuildId)"
    $state.flash_state = 'EXACT_RELEASE_RUNNING'
    $state.postflash_identity_at = [DateTimeOffset]::UtcNow.ToString('o')
    Write-JsonFile $persistState $state
    Write-Host 'POSTFLASH_EXACT_RELEASE_IDENTITY=PASS'
}

$verifyArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'scripts\real-device-verify-v3.ps1'),'-Candidate',[string]$Request.candidate_tag,'-Commit',[string]$Request.source_sha,'-Target','root@192.168.6.1','-Mode','PostFlash')
$verify = Invoke-NativeCaptured -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments $verifyArgs -AllowFailure
Write-Host $verify.Output
Require ($verify.ExitCode -eq 0) 'POSTFLASH_BASE_VERIFICATION_FAILED' "exit=$($verify.ExitCode)"
Write-Host 'POSTFLASH_BASE_VERIFICATION=PASS'

$access = Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1'
$knownHosts = [string]$access.KnownHosts
$afterRebootBuild = Get-ArthurHttpBuildInfo -DeviceIp '192.168.6.1' -Policy $policy
$afterRebootFields = Get-ArthurBuildIdentityFields -Build $afterRebootBuild
Require ([string]$afterRebootFields.Version -eq '0.1.6' -and [string]$afterRebootFields.BuildId -eq '38000704263') 'POSTREBOOT_EXACT_RELEASE_IDENTITY_MISMATCH' 'exact v0.1.6 identity did not persist'

$quickfile = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'test -x /etc/init.d/quickfile && /etc/init.d/quickfile enabled && pgrep -af "[q]uickfile" && find /tmp/run /var/run -maxdepth 4 -type s -name "*quickfile*" 2>/dev/null | head -n 5'
Require ($quickfile.ExitCode -eq 0 -and $quickfile.Output -match '(?i)quickfile') 'QUICKFILE_BACKEND_FAIL' $quickfile.Output
$linkease = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'apk info 2>/dev/null | grep -Fx "linkease-common-bin" && apk info 2>/dev/null | grep -Fx "linkease" && apk info 2>/dev/null | grep -Fx "luci-lib-linkeasefile" && apk info 2>/dev/null | grep -Fx "luci-app-linkease" && pgrep -af "[l]inkease" && find /tmp/run /var/run -maxdepth 4 -type s -name "*linkease*" 2>/dev/null | head -n 5'
Require ($linkease.ExitCode -eq 0 -and $linkease.Output -match '(?i)linkease') 'LINKEASE_BACKEND_FAIL' $linkease.Output
$mount = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'mount | grep -F "/mnt/mmcblk0p27" && test -d /mnt/mmcblk0p27/Public && test -d /mnt/mmcblk0p27/download && test -d /mnt/mmcblk0p27/Configs && printf "FILE_DIRS=PASS\n"'
Require ($mount.ExitCode -eq 0 -and $mount.Output -match 'FILE_DIRS=PASS') 'MMCBLK0P27_BROWSE_FAIL' $mount.Output
$linkeaseUci = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'uci -q show linkease 2>/dev/null || true'
Require ($linkeaseUci.Output -match "(?im)allowPublic='?0'?") 'LINKEASE_PUBLIC_ACCESS_UNSAFE' 'allowPublic=0 not proven'
$firewall = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'if uci -q show firewall 2>/dev/null | grep -q "8897"; then exit 41; fi; if nft list ruleset 2>/dev/null | grep -q "8897"; then exit 42; fi; exit 0' -AllowFailure
Require ($firewall.ExitCode -eq 0) 'LINKEASE_WAN_8897_RULE_PRESENT' $firewall.Output

$session = New-RootLuciCookie -KnownHosts $knownHosts
try {
    $quickfilePage = Invoke-LuciGet -Cookie $session.Cookie -Path '/cgi-bin/luci/admin/system/quickfile'
    Require ($quickfilePage.ExitCode -eq 0 -and $quickfilePage.HttpCode -eq '200') 'QUICKFILE_UI_FAIL' "http=$($quickfilePage.HttpCode)"
    Require ($quickfilePage.Body -notmatch '(?i)502 Bad Gateway|404 未找到|404 Not Found|x-luci-login-required|login-page') 'QUICKFILE_UI_FAIL' 'QuickFile error/login page'
    $linkeasePage = Invoke-LuciGet -Cookie $session.Cookie -Path '/cgi-bin/luci/admin/services/linkease/file/?path=/data_mmcblk0p27'
    Require ($linkeasePage.ExitCode -eq 0 -and $linkeasePage.HttpCode -eq '200') 'LINKEASE_FILE_UI_FAIL' "http=$($linkeasePage.HttpCode)"
    Require ($linkeasePage.Body -notmatch '(?i)502 Bad Gateway|404 未找到|404 Not Found|No page is registered|x-luci-login-required|login-page') 'LINKEASE_FILE_UI_FAIL' 'LinkEase file route error/login page'
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $session.Cookie
    $destroyPayload = @{ ubus_rpc_session=[string]$session.Session } | ConvertTo-Json -Compress
    Invoke-StrictSsh -KnownHosts $knownHosts -Command "ubus call session destroy '$destroyPayload'" -AllowFailure | Out-Null
}

$baseReport = Join-Path $Root 'output\real-device\real-device-verification.json'
Require (Test-Path $baseReport) 'REAL_DEVICE_REPORT_MISSING' 'canonical post-flash report missing'
$base = Get-Content -Raw $baseReport | ConvertFrom-Json
Require ([string]$base.result -eq 'PASS') 'REAL_DEVICE_REPORT_FAIL' 'canonical report is not PASS'
Require ([string]$base.candidate -eq [string]$Request.candidate_tag) 'REAL_DEVICE_REPORT_IDENTITY_MISMATCH' 'candidate mismatch'
Require ([string]$base.commit -eq [string]$Request.source_sha) 'REAL_DEVICE_REPORT_IDENTITY_MISMATCH' 'source mismatch'

$fileEvidence = [ordered]@{
    schema_version=1;status='PASS';release_tag=[string]$Request.release_tag;candidate_tag=[string]$Request.candidate_tag;
    source_sha=[string]$Request.source_sha;build_run_id=[long]$Request.build_run_id;artifact_id=[long]$Request.artifact_id;
    actions_artifact_sha256=[string]$Request.actions_artifact_sha256;sysupgrade_sha256=$stableHash;
    device_build_id=[string]$afterRebootFields.BuildId;observed_at=[DateTimeOffset]::UtcNow.ToString('o');
    markers=[ordered]@{DEVICE_EXACT_ARTIFACT_MATCH='PASS';POSTFLASH_BASE_VERIFICATION='PASS';REBOOT_PERSISTENCE='PASS';QUICKSTART_LINKEASE_FILE_MANAGER='PASS';LINKEASE_MMCBLK0P27_BROWSE='PASS';QUICKFILE_BACKEND='PASS';QUICKFILE_UI='PASS';NO_FILE_MANAGEMENT_404_502='PASS';WAN_8897_RULE_ADDED='NO';LINKEASE_ALLOW_PUBLIC='0'};
    rollback=[ordered]@{tag=[string]$Request.rollback_tag;sha256=$rollbackHash;available=$true};errors=@()
}
$fileEvidencePath = Join-Path $Root 'output\real-device\v016-file-management-postflash.json'
Write-JsonFile $fileEvidencePath $fileEvidence
Write-Host 'DEVICE_EXACT_ARTIFACT_MATCH=PASS'
Write-Host 'QUICKSTART_LINKEASE_FILE_MANAGER=PASS'
Write-Host 'LINKEASE_MMCBLK0P27_BROWSE=PASS'
Write-Host 'QUICKFILE_BACKEND=PASS'
Write-Host 'QUICKFILE_UI=PASS'
Write-Host 'NO_FILE_MANAGEMENT_404_502=PASS'
Write-Host 'POST_RELEASE_BASE_AND_FILE_MANAGEMENT=PASS'
