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

function Invoke-StrictSsh {
    param([string]$KnownHosts,[string]$Command)
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { $ssh = Get-Command ssh -ErrorAction Stop }
    $args = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$KnownHosts",'-o','ConnectTimeout=10','root@192.168.6.1',$Command)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $ssh.Source @args 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ ExitCode=$code; Output=(($raw | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Write-JsonFile([string]$Path,$Object) {
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Object | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function ConvertTo-SanitizedPostFlashVerifierOutput {
    param([AllowEmptyString()][string]$Text)

    $safe = [string]$Text
    if (-not [string]::IsNullOrEmpty($env:ARTHUR_ROOT_PASSWORD)) {
        $safe = $safe.Replace($env:ARTHUR_ROOT_PASSWORD,'[REDACTED]')
    }
    $safe = [regex]::Replace($safe,'(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----','[REDACTED PRIVATE KEY]')
    $safe = [regex]::Replace($safe,'(?i)\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})\b','[REDACTED TOKEN]')
    $safe = [regex]::Replace($safe,'(?i)(\bBearer\s+)[A-Za-z0-9._~+/-]+=*','$1[REDACTED]')
    $safe = [regex]::Replace($safe,'(?im)(^\s*(?:cookie|set-cookie|authorization|proxy-authorization)\s*[:=]\s*).+$','$1[REDACTED]')
    $safe = [regex]::Replace($safe,'(?i)((?:\bpassword|\bpasswd|\btoken|\baccess[_-]?token|\brefresh[_-]?token|\bapi[_-]?key|\bsecret|\bsysauth_http|\bubus_rpc_session)\s*[:=]\s*)[^\s,;"'']+','$1[REDACTED]')
    $safe = [regex]::Replace($safe,'(?i)(https?://[^\s]*(?:subscribe|subscription)[^\s]*)','[REDACTED SUBSCRIPTION URL]')
    $safe = [regex]::Replace($safe,'(?i)\b(?:ss|ssr|vmess|vless|trojan|hysteria2?|tuic)://[^\s,;"'']+','[REDACTED SUBSCRIPTION CONTENT]')
    $safe = [regex]::Replace($safe,'(?im)(^\s*(?:subscription|subscribe|proxy[-_ ]?provider|proxies)\s*[:=]\s*).+$','$1[REDACTED SUBSCRIPTION CONTENT]')
    return $safe
}

function Get-PostFlashBaseFirstFailure {
    param([AllowEmptyString()][string]$Text)

    $explicit = [regex]::Match($Text,'(?im)^\s*FIRST_FAILURE\s*[:=]\s*(?<marker>[A-Za-z0-9][A-Za-z0-9_.:-]*)')
    if ($explicit.Success) { return $explicit.Groups['marker'].Value }

    $failedMarker = [regex]::Match($Text,'(?im)^\s*(?<marker>[A-Za-z][A-Za-z0-9_.:-]*)\s*=\s*(?:FAIL|FAILED|BLOCKED)(?=\s|$|:)')
    if ($failedMarker.Success) { return $failedMarker.Groups['marker'].Value }

    $failedCheck = [regex]::Match($Text,'(?im)^\s*(?<marker>[A-Za-z][A-Za-z0-9_.:-]*)\s*[:=]\s*(?:FAIL|FAILED|BLOCKED)\b')
    if ($failedCheck.Success) { return $failedCheck.Groups['marker'].Value }
    return 'MARKER_NOT_FOUND'
}

function Complete-PostFlashBaseVerification {
    param(
        [AllowEmptyCollection()][object[]]$Output,
        [int]$ExitCode,
        [Parameter(Mandatory=$true)][string]$LogPath
    )

    $rawText = (($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    $safeText = ConvertTo-SanitizedPostFlashVerifierOutput -Text $rawText
    $logDirectory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    [IO.File]::WriteAllText($LogPath,$safeText,[Text.UTF8Encoding]::new($false))

    Write-Host 'POSTFLASH_BASE_VERIFIER_OUTPUT_BEGIN'
    if (-not [string]::IsNullOrEmpty($safeText)) { Write-Host $safeText }
    Write-Host 'POSTFLASH_BASE_VERIFIER_OUTPUT_END'

    if ($ExitCode -ne 0) {
        $firstFailure = Get-PostFlashBaseFirstFailure -Text $safeText
        Write-Host "POSTFLASH_BASE_FIRST_FAILURE=$firstFailure"
        throw "POSTFLASH_BASE_VERIFICATION_FAILED exit=$ExitCode"
    }
    Write-Host 'POSTFLASH_BASE_VERIFICATION=PASS'
    return $true
}

function New-RootLuciCookie {
    param([string]$KnownHosts)
    $create = Invoke-StrictSsh -KnownHosts $KnownHosts -Command 'ubus call session create'
    Require ($create.ExitCode -eq 0) 'LUCI_SESSION_CREATE_FAILED' 'authenticated LuCI session creation failed'
    try { $obj = $create.Output | ConvertFrom-Json } catch { Fail 'LUCI_SESSION_CREATE_INVALID_JSON' 'ubus did not return valid JSON' }
    $sid = [string]$obj.ubus_rpc_session
    Require (-not [string]::IsNullOrWhiteSpace($sid)) 'LUCI_SESSION_ID_MISSING' 'ubus did not return a session id'
    $token = [Guid]::NewGuid().ToString('N')
    $setPayload = @{ubus_rpc_session=$sid;values=@{username='root';token=$token}} | ConvertTo-Json -Compress
    $ubusPayload = @{ubus_rpc_session=$sid;scope='ubus';objects=@(@('*','*'))} | ConvertTo-Json -Compress
    $filePayload = @{ubus_rpc_session=$sid;scope='file';objects=@(@('*','*'))} | ConvertTo-Json -Compress
    foreach ($entry in @(
        "ubus call session set '$setPayload'",
        "ubus call session grant '$ubusPayload'",
        "ubus call session grant '$filePayload'"
    )) {
        $result = Invoke-StrictSsh -KnownHosts $KnownHosts -Command $entry
        Require ($result.ExitCode -eq 0) 'LUCI_SESSION_GRANT_FAILED' 'authenticated LuCI session setup failed'
    }
    $cookie = Join-Path $env:RUNNER_TEMP ("arthur-v016-resume-luci-{0}.cookie" -f [Guid]::NewGuid().ToString('N'))
    $tab = [char]9
    $cookieLine = '192.168.6.1' + $tab + 'FALSE' + $tab + '/' + $tab + 'FALSE' + $tab + '0' + $tab + 'sysauth_http' + $tab + $sid
    @('# Netscape HTTP Cookie File',$cookieLine) | Set-Content -Encoding ASCII -LiteralPath $cookie
    [pscustomobject]@{Cookie=$cookie;Session=$sid}
}

function Invoke-LuciGet {
    param([string]$Cookie,[string]$Path)
    $body = Join-Path $env:RUNNER_TEMP ("arthur-v016-resume-luci-body-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    try {
        $raw = @(& $curl -sS -L --max-time 25 -b $Cookie -o $body -w '%{http_code}' "http://192.168.6.1$Path" 2>&1)
        $code = $LASTEXITCODE
        $http = (($raw | ForEach-Object { [string]$_ }) -join '').Trim()
        $content = if (Test-Path -LiteralPath $body) { Get-Content -Raw -LiteralPath $body } else { '' }
        [pscustomobject]@{ExitCode=$code;HttpCode=$http;Body=$content}
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $body }
}

Require ([int]$Request.schema_version -eq 1) 'REQUEST_SCHEMA_INVALID' 'schema_version must be 1'
Require ([string]$Request.status -eq 'AUTHORIZED') 'POST_RELEASE_TEST_NOT_AUTHORIZED' 'request status must be AUTHORIZED'
Require ($Request.device_write_authorized -eq $true) 'DEVICE_WRITE_NOT_AUTHORIZED' 'runner-key recovery must be authorized by the post-release request'
Require ([string]$Request.authorization_scope -eq 'POST_RELEASE_DEVICE_TEST_ONLY') 'AUTHORIZATION_SCOPE_INVALID' 'request must authorize post-release validation only'
Require ([string]$Request.release_tag -eq 'v0.1.6') 'RELEASE_IDENTITY_MISMATCH' 'unexpected release tag'
Require ([string]$Request.candidate_tag -eq 'arthur-update-38000704263') 'CANDIDATE_IDENTITY_MISMATCH' 'unexpected Candidate tag'
Require ([string]$Request.source_sha -eq 'b4448e62ab1e767f9a60221b0600c60c355baf56') 'SOURCE_IDENTITY_MISMATCH' 'unexpected source SHA'
Require ([long]$Request.build_run_id -eq 38000704263) 'BUILD_IDENTITY_MISMATCH' 'unexpected build run'
Require ([long]$Request.artifact_id -eq 11655711894) 'ARTIFACT_IDENTITY_MISMATCH' 'unexpected artifact id'
Require ([string]$Request.sysupgrade_sha256 -eq 'e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39') 'FIRMWARE_IDENTITY_MISMATCH' 'unexpected released artifact hash'
Require ([string]$Request.management_ip -eq '192.168.6.1') 'DEVICE_IDENTITY_MISMATCH' 'unexpected management IP'
Require ([string]$Request.management_mac -eq 'dc:d8:7c:45:91:99') 'DEVICE_IDENTITY_MISMATCH' 'unexpected management MAC'
Require ([string]$Status.status -eq 'PRODUCTION_RELEASED') 'RELEASE_STATE_INVALID' 'v0.1.6 must already be PRODUCTION_RELEASED'
Require ([string]$Status.version -eq 'v0.1.6' -and [long]$Status.run_id -eq 38000704263) 'RELEASE_STATE_INVALID' 'release state identity mismatch'
Require ([string]$Status.source_commit -eq [string]$Request.source_sha -and [long]$Status.artifact_id -eq [long]$Request.artifact_id) 'RELEASE_STATE_INVALID' 'source or artifact identity mismatch'
Require ([string]$Status.post_release_device_test -eq 'PENDING_INDEPENDENT') 'POST_RELEASE_STATE_INVALID' 'post-release test is no longer pending'

$AccessHelper = Join-Path $PSScriptRoot 'ensure-arthur-unattended-access.ps1'
. $AccessHelper
$policy = Get-ArthurAccessPolicy
$ethernet = Assert-ArthurEthernetIdentity -DeviceIp '192.168.6.1' -Policy $policy
$httpFields = Get-ArthurBuildIdentityFields -Build $ethernet.Build
Require ($ethernet.Network.Mac -eq 'dc:d8:7c:45:91:99') 'STOP=POSTFLASH_EXACT_RELEASE_IDENTITY_LOST' 'Ethernet neighbor identity is not the authorized Arthur MAC'
Require ($httpFields.Firmware -eq 'XinZhaoWrt' -and $httpFields.Version -eq '0.1.6' -and $httpFields.BuildId -eq '38000704263' -and $httpFields.Target -eq 'qualcommax/ipq60xx' -and $httpFields.Profile -eq 'jdcloud_re-ss-01') 'STOP=POSTFLASH_EXACT_RELEASE_IDENTITY_LOST' 'HTTP build-info does not match the exact released image'
Write-Host 'FLASH_ALREADY_CONSUMED=YES'
Write-Host 'SECOND_FLASH_EXECUTED=NO'
Write-Host 'CURRENT_MANAGEMENT_IP=192.168.6.1'
Write-Host 'CURRENT_VERSION=0.1.6'
Write-Host 'CURRENT_BUILD_ID=38000704263'
Write-Host 'CURRENT_MANAGEMENT_MAC=dc:d8:7c:45:91:99'
Write-Host 'POSTFLASH_EXACT_RELEASE_IDENTITY=HTTP_AND_ETHERNET_PASS'

$tempKnownHosts = Join-Path $env:RUNNER_TEMP ("arthur-v016-resume-candidate-{0}.known_hosts" -f [Guid]::NewGuid().ToString('N'))
try {
    $passwordIdentity = Invoke-ArthurSshProbe -DeviceIp '192.168.6.1' -KnownHostsFile $tempKnownHosts -StrictMode accept-new -Command (Get-ArthurReadOnlyIdentityCommand) -PasswordAuth
    Require (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $passwordIdentity -Policy $policy -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263') 'POSTFLASH_AUTHENTICATED_IDENTITY' 'password-authenticated identity did not match exact Arthur release and MAC'
    Write-Host 'PASSWORD_AUTH_IDENTITY=PASS'

    $access = Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1' -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263'
    $knownHosts = [string]$access.KnownHosts
    $keyIdentity = Invoke-ArthurSshProbe -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -StrictMode yes -Command (Get-ArthurReadOnlyIdentityCommand)
    Require (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $keyIdentity -Policy $policy -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263') 'RUNNER_KEY_AUTH' 'strict runner-key authentication did not prove the exact Arthur release and MAC'
    Write-Host 'RUNNER_KEY_AUTH=PASS'
    Write-Host 'SSH_HOST_TRUST=PASS'
    Write-Host 'ARTHUR_UNATTENDED_ACCESS=PASS'
    Write-Host 'POSTFLASH_AUTHENTICATED_IDENTITY=PASS'
}
finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempKnownHosts }

$verifier = Join-Path $PSScriptRoot 'real-device-verify-v3.ps1'
$verifyArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifier,'-Candidate','arthur-update-38000704263','-Commit','b4448e62ab1e767f9a60221b0600c60c355baf56','-Target','root@192.168.6.1','-Mode','PostFlash')
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$oldPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $verifyOutput = @(& $pwsh @verifyArgs 2>&1)
    $verifyExit = $LASTEXITCODE
}
finally { $ErrorActionPreference = $oldPreference }
$verifyLogPath = Join-Path $Root 'output\real-device\postflash-base-verifier.log'
Complete-PostFlashBaseVerification -Output $verifyOutput -ExitCode $verifyExit -LogPath $verifyLogPath | Out-Null

$postNetwork = Assert-ArthurEthernetIdentity -DeviceIp '192.168.6.1' -Policy $policy
$postFields = Get-ArthurBuildIdentityFields -Build $postNetwork.Build
Require ($postNetwork.Network.Mac -eq 'dc:d8:7c:45:91:99' -and $postFields.Version -eq '0.1.6' -and $postFields.BuildId -eq '38000704263' -and $postFields.Target -eq 'qualcommax/ipq60xx' -and $postFields.Profile -eq 'jdcloud_re-ss-01') 'POSTFLASH_EXACT_RELEASE_IDENTITY_LOST' 'exact release identity did not survive canonical PostFlash validation'
$access = Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1' -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263'
$knownHosts = [string]$access.KnownHosts
$strictIdentity = Invoke-ArthurSshProbe -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -StrictMode yes -Command (Get-ArthurReadOnlyIdentityCommand)
Require (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $strictIdentity -Policy $policy -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263') 'POSTFLASH_AUTHENTICATED_IDENTITY' 'strict post-reboot SSH identity did not match exact release'

$quickfile = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'test -x /etc/init.d/quickfile && /etc/init.d/quickfile enabled && /etc/init.d/quickfile status && pgrep -af "[q]uickfile" && find /tmp/run /var/run -maxdepth 4 -type s -name "*quickfile*" 2>/dev/null | head -n 5'
Require ($quickfile.ExitCode -eq 0 -and $quickfile.Output -match '(?i)quickfile') 'QUICKFILE_BACKEND_FAIL' 'QuickFile service, process, or socket is unavailable'
$linkease = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'test -x /etc/init.d/linkease && /etc/init.d/linkease status && apk info 2>/dev/null | grep -Fx "linkease-common-bin" && apk info 2>/dev/null | grep -Fx "linkease" && apk info 2>/dev/null | grep -Fx "luci-lib-linkeasefile" && apk info 2>/dev/null | grep -Fx "luci-app-linkease" && pgrep -af "[l]inkease" && find /tmp/run /var/run -maxdepth 4 -type s -name "*linkease*" 2>/dev/null | head -n 5'
Require ($linkease.ExitCode -eq 0 -and $linkease.Output -match '(?i)linkease') 'LINKEASE_BACKEND_FAIL' 'LinkEase service, packages, process, or socket is unavailable'
$mount = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'mount | grep -F "/mnt/mmcblk0p27" && test -r /mnt/mmcblk0p27 && test -d /mnt/mmcblk0p27/Public && test -d /mnt/mmcblk0p27/download && test -d /mnt/mmcblk0p27/Configs && ls -1 /mnt/mmcblk0p27'
Require ($mount.ExitCode -eq 0 -and $mount.Output -match '(?im)^Public$' -and $mount.Output -match '(?im)^download$' -and $mount.Output -match '(?im)^Configs$') 'MMCBLK0P27_BROWSE_FAIL' 'expected data directories are not browseable on the existing mount'
$linkeaseUci = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'uci -q show linkease 2>/dev/null || true'
Require ($linkeaseUci.Output -match "(?im)allowPublic='?0'?") 'LINKEASE_PUBLIC_ACCESS_UNSAFE' 'allowPublic=0 was not proven'
$firewall = Invoke-StrictSsh -KnownHosts $knownHosts -Command 'command -v nft >/dev/null || exit 43; if uci -q show firewall 2>/dev/null | grep -q "8897"; then exit 41; fi; if nft list ruleset 2>/dev/null | grep -q "8897"; then exit 42; fi; printf "WAN_8897_RULE_ADDED=NO\n"'
Require ($firewall.ExitCode -eq 0 -and $firewall.Output -match 'WAN_8897_RULE_ADDED=NO') 'LINKEASE_WAN_8897_RULE_PRESENT' 'WAN port 8897 rule was found or firewall state could not be checked'

$session = New-RootLuciCookie -KnownHosts $knownHosts
try {
    $quickfilePage = Invoke-LuciGet -Cookie $session.Cookie -Path '/cgi-bin/luci/admin/system/quickfile'
    Require ($quickfilePage.ExitCode -eq 0 -and $quickfilePage.HttpCode -eq '200') 'QUICKFILE_UI_FAIL' 'QuickFile LuCI route did not return HTTP 200'
    Require ($quickfilePage.Body -notmatch '(?i)502 Bad Gateway|404 Not Found|404 未找到|x-luci-login-required|login-page') 'QUICKFILE_UI_FAIL' 'QuickFile response contains an error or login page'
    $linkeasePage = Invoke-LuciGet -Cookie $session.Cookie -Path '/cgi-bin/luci/admin/services/linkease/file/?path=/data_mmcblk0p27'
    Require ($linkeasePage.ExitCode -eq 0 -and $linkeasePage.HttpCode -eq '200') 'LINKEASE_FILE_UI_FAIL' 'LinkEase file route did not return HTTP 200'
    Require ($linkeasePage.Body -notmatch '(?i)502 Bad Gateway|404 Not Found|404 未找到|No page is registered|x-luci-login-required|login-page') 'LINKEASE_FILE_UI_FAIL' 'LinkEase file response contains an error or login page'
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $session.Cookie
    $destroy = @{ubus_rpc_session=[string]$session.Session} | ConvertTo-Json -Compress
    Invoke-StrictSsh -KnownHosts $knownHosts -Command "ubus call session destroy '$destroy'" | Out-Null
}

$evidence = [ordered]@{
    schema_version=1;status='PASS';release_tag=[string]$Request.release_tag;candidate_tag=[string]$Request.candidate_tag;
    source_sha=[string]$Request.source_sha;build_run_id=[long]$Request.build_run_id;artifact_id=[long]$Request.artifact_id;
    actions_artifact_sha256=[string]$Request.actions_artifact_sha256;sysupgrade_sha256=[string]$Request.sysupgrade_sha256;
    device_build_id=$postFields.BuildId;observed_at=[DateTimeOffset]::UtcNow.ToString('o');
    markers=[ordered]@{
        DEVICE_EXACT_ARTIFACT_MATCH='PASS';POSTFLASH_BASE_VERIFICATION='PASS';REBOOT_PERSISTENCE='PASS';
        QUICKSTART_LINKEASE_FILE_MANAGER='PASS';LINKEASE_MMCBLK0P27_BROWSE='PASS';QUICKFILE_BACKEND='PASS';QUICKFILE_UI='PASS';
        NO_FILE_MANAGEMENT_404_502='PASS';WAN_8897_RULE_ADDED='NO';LINKEASE_ALLOW_PUBLIC='0'
    };
    observations=[ordered]@{
        ethernet=[ordered]@{interface=[string]$postNetwork.Network.Adapter.Name;mac=[string]$postNetwork.Network.Mac;management_ip='192.168.6.1'};
        http_build=[ordered]@{firmware=$postFields.Firmware;version=$postFields.Version;build_id=$postFields.BuildId;target=$postFields.Target;profile=$postFields.Profile};
        ssh=[ordered]@{password_identity='PASS';runner_key='PASS';host_trust='PASS'};
        quickfile=[ordered]@{http_status=[int]$quickfilePage.HttpCode;service_process_socket=[string]$quickfile.Output};
        linkease=[ordered]@{http_status=[int]$linkeasePage.HttpCode;mount_and_directories=[string]$mount.Output;allow_public='0';wan_8897_rule='NO'}
    };
    rollback=[ordered]@{tag=[string]$Request.rollback_tag;sha256=[string]$Request.rollback_sha256;availability='NOT_RECHECKED_RESUME_ONLY'};errors=@()
}
$evidencePath = Join-Path $Root 'output\real-device\v016-file-management-postflash.json'
Write-JsonFile $evidencePath $evidence
Write-Host 'QUICKSTART_LINKEASE_FILE_MANAGER=PASS'
Write-Host 'LINKEASE_MMCBLK0P27_BROWSE=PASS'
Write-Host 'QUICKFILE_BACKEND=PASS'
Write-Host 'QUICKFILE_UI=PASS'
Write-Host 'NO_FILE_MANAGEMENT_404_502=PASS'
Write-Host 'WAN_8897_RULE_ADDED=NO'
Write-Host 'LINKEASE_ALLOW_PUBLIC=0'
Write-Host 'POST_RELEASE_BASE_AND_FILE_MANAGEMENT=PASS'
