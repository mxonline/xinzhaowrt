$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

$buildEnv = Get-Content -Raw (Join-Path $Root 'build.env')
$defaults = Get-Content -Raw (Join-Path $Root 'files/etc/uci-defaults/99-xinzhao-defaults')
$arthurConfig = Get-Content -Raw (Join-Path $Root 'config/arthur.config')
$deploy = Get-Content -Raw (Join-Path $Root '.github/workflows/production-agent-deploy.yml')
$controlPlane = Get-Content -Raw (Join-Path $Root 'scripts/arthur-control-plane.ps1')
$themeLock = Get-Content -Raw (Join-Path $Root 'config/arthur-theme.lock')
$requirementsPath = Join-Path $Root 'requirements-headless.txt'

Assert-Contains $buildEnv 'DEFAULT_WIFI_SSID="xinzhaowrt"' 'formal product baseline must preserve approved Wi-Fi SSID'
Assert-Contains $buildEnv 'DEFAULT_WIFI_PASSWORD="12345678"' 'formal product baseline must preserve approved Wi-Fi credential'
Assert-Contains $defaults "wifi_default_ssid='xinzhaowrt'" 'first-boot defaults must apply approved Wi-Fi SSID'
Assert-Contains $defaults "wifi_default_password='12345678'" 'first-boot defaults must apply approved Wi-Fi credential'
Assert-Contains $defaults 'uci commit wireless' 'first-boot defaults must persist Wi-Fi settings'
Assert-Contains $defaults 'wifi reload' 'first-boot defaults must reload wireless after committed defaults'

Assert-Contains $arthurConfig 'CONFIG_PACKAGE_luci-theme-argon=y' 'formal Arthur production config must include Argon'
Assert-Contains $arthurConfig 'CONFIG_PACKAGE_luci-theme-kucat=y' 'formal Arthur production config must include Kucat'
Assert-Contains $themeLock 'ARGON_REF="136eb5d42f30554e89cc737fd90f503909810660"' 'Argon source ref must stay frozen to the verified source'
Assert-Contains $themeLock 'KUCAT_REF="82ddd7e4196887089c43af19d4552cd54fa414d2"' 'Kucat source ref must stay frozen to the verified source'

foreach ($relative in @(
    'ai_orchestrator/__init__.py',
    'ai_orchestrator/__main__.py',
    'ai_orchestrator/adapters.py',
    'ai_orchestrator/runtime.py',
    'ai_orchestrator/supervisor.py',
    'scripts/run-supervisor.py'
)) {
    Assert-True (Test-Path (Join-Path $Root $relative)) "existing GPT-Codex Bridge runtime file must be present: $relative"
}

# The active deployment path now wakes the one runner-owned Control Plane; that script owns the ai_orchestrator resume call.
Assert-Contains $deploy 'scripts\arthur-control-plane.ps1' 'runner wakeup must delegate to the existing Arthur Control Plane'
Assert-Contains $controlPlane 'python -m ai_orchestrator resume' 'Control Plane must invoke the existing GPT-Codex decision runtime'
Assert-Contains $deploy 'HEADLESS_RUNTIME=REUSE' 'deployment must reuse the already-proven persistent Python/Codex SDK runtime before bootstrap'
Assert-Contains $deploy 'python install 3.12' 'bootstrap fallback must install pinned Python 3.12 in user space'
Assert-Contains $deploy 'HeadlessPython' 'deployment must keep the supported Bridge interpreter in a persistent user-space directory'
Assert-Contains $deploy 'HEADLESS_PYTHON_EXE' 'deployment must carry the pinned Python path for headless decision calls'
Assert-True ($deploy -notmatch 'astral-sh/setup-uv@v6') 'deployment must not depend on the flaky setup-uv Node action on the self-hosted Windows runner'
Assert-True ($deploy -notmatch 'XinZhaoWrt-GPT-Codex-Bridge-Supervisor') 'active wakeup must not revive the obsolete standalone Bridge supervisor'
Assert-True ($deploy -notmatch 'LogonType\s+Interactive') 'active wakeup must not depend on an interactive Windows session'
Assert-True (Test-Path $requirementsPath) 'deployment must retain the existing headless runtime dependency input'
$requirements = Get-Content -Raw $requirementsPath
Assert-Contains $requirements 'openai-codex' 'headless runtime must install the existing Codex SDK dependency'

foreach ($asset in @(
    'files/www/luci-static/xinzhao/favicon.ico',
    'files/www/luci-static/xinzhao/favicon-32x32.png',
    'files/www/luci-static/xinzhao/favicon-192x192.png',
    'files/www/luci-static/xinzhao/apple-touch-icon.png',
    'files/www/luci-static/xinzhao/logo.png'
)) {
    Assert-True (Test-Path (Join-Path $Root $asset)) "verified XinZhaoWrt branding asset must be inherited: $asset"
}

Write-Host 'VERIFIED_BASELINE_INHERITANCE_CONTRACT=PASS'
