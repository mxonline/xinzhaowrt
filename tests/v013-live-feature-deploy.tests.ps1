$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $Root 'scripts\live-validate-v013-features.ps1'
$workflow = Join-Path $Root '.github\workflows\arthur-v013-prebuild-live.yml'

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "V013_LIVE_DEPLOY_CONTRACT: FAIL -- $Message" }
}

Assert-True (Test-Path $script) 'live validation script is missing'
$text = Get-Content -Raw $script

Assert-True ($text -match "ExpectedVersion\s*=\s*'0\.1\.3'") 'script must bind to physical version 0.1.3'
Assert-True ($text -match "ExpectedBuildId\s*=\s*'33462873812'") 'script must bind to physical Build ID 33462873812'
Assert-True ($text -match 'build-info\.json') 'script must machine-check live build identity'
Assert-True ($text -match 'xinzhaowrt-runtime-backup') 'script must create a runtime rollback backup'
Assert-True ($text -match 'adguardhome.*BackupDir/adguardhome') 'script must back up the AdGuard UCI config before enabling it'
Assert-True ($text -match 'luci-app-adguardhome\.json') 'script must deploy the AdGuard rpcd ACL'
Assert-True ($text -match 'adguardhome\\config\.js|adguardhome/config\.js') 'script must deploy the AdGuard LuCI manager'
Assert-True ($text -match "homepage='admin/quickstart'") 'script must set QuickStart as LuCI homepage'
Assert-True ($text -match "ssid=xinzhaowrt") 'script must set both radio SSIDs to xinzhaowrt'
Assert-True ($text -match "key=12345678") 'script must set the requested Wi-Fi password'
Assert-True ($text -match 'adguardhome.*stop') 'script must leave AdGuard Home stopped'
Assert-True ($text -match 'adguardhome.*disable') 'script must leave AdGuard Home disabled'
Assert-True ($text -match 'uci\s+set\s+adguardhome\.config\.enabled=1') 'script must enable AdGuard UCI for the live start check'
Assert-True ($text -match 'uci\s+set\s+adguardhome\.config\.enabled=0') 'script must disable AdGuard UCI after the live start check'
$unsafeRemoteSubstitution = $text -split "`r?`n" | Where-Object { $_ -match 'Assert-RemoteOutput "' -and $_ -match '\$\(' }
Assert-True (-not $unsafeRemoteSubstitution) 'remote UCI command substitutions must not be expanded by PowerShell'
Assert-True ($text -match 'Get-NetRoute|InterfaceAlias') 'script must verify the runner path before Wi-Fi reload'
Assert-True ($text -match '\$Command\s*=\s*\$Command\.Replace\("`r`n",\s*"`n"\)\.Replace\("`r",\s*"`n"\)') 'remote multiline commands must normalize Windows CRLF to LF before BusyBox ash'
Assert-True ($text -cmatch '&\s+scp\.exe\s+-O\s+-o\s+BatchMode') 'Arthur Dropbear copies must force uppercase -O legacy SCP before SSH options'
Assert-True ($text -match '\$previousErrorActionPreference\s*=\s*\$ErrorActionPreference') 'native SSH/SCP calls must preserve the caller error preference'
Assert-True ($text -match '\$ErrorActionPreference\s*=\s*''Continue''') 'native SSH/SCP stderr must not terminate Windows PowerShell validation'
Assert-True ($text -match '\$ErrorActionPreference\s*=\s*\$previousErrorActionPreference') 'native SSH/SCP calls must restore the caller error preference'
Assert-True ($text -match "pgrep\s+-f\s+'\[A\]dGuardHome'") 'AdGuard process checks must not match their own pgrep command'
Assert-True ($text -notmatch '(?i)sysupgrade|\bmtd\b|\buboot\b|\bu-boot\b|/dev/mmcblk|\bdd\s+if=') 'live validation must never contain firmware/raw-write commands'

$catch = [regex]::Match($text, '(?s)catch\s*\{\s*\$message\s*=\s*\$_\.Exception\.Message(?<body>.*?)\n\}')
Assert-True $catch.Success 'live validation catch block is missing'
$catchBody = $catch.Groups['body'].Value
$restoreIndex = $catchBody.IndexOf('Restore-RuntimeBackup')
$writeErrorIndex = $catchBody.IndexOf('Write-Error')
Assert-True ($restoreIndex -ge 0) 'failure path must call Restore-RuntimeBackup'
Assert-True ($writeErrorIndex -lt 0 -or $restoreIndex -lt $writeErrorIndex) 'rollback must execute before any terminating Write-Error'

Assert-True (Test-Path $workflow) 'one-shot live validation workflow is missing'
$workflowText = Get-Content -Raw $workflow
Assert-True ($workflowText -match '(?m)^\s*shell:\s*powershell\s*$') 'self-hosted live workflow must use built-in Windows PowerShell'
Assert-True ($workflowText -notmatch '(?m)^\s*shell:\s*pwsh\s*$') 'self-hosted live workflow must not require unavailable pwsh'
Assert-True ($workflowText -match 'live-validate-v013-features\.ps1') 'live workflow must execute the guarded validation script'

Write-Host 'V013_LIVE_DEPLOY_CONTRACT=PASS'
