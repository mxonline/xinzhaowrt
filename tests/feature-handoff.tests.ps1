$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal($Actual,$Expected,[string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "TEST_FAIL: $Message actual='$Actual' expected='$Expected'" }
}
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message missing='$Needle'"
    }
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $threw = $false
    try { & $Action } catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "TEST_FAIL: $Message wrong error='$($_.Exception.Message)' expected-pattern='$Pattern'"
        }
    }
    if (-not $threw) { throw "TEST_FAIL: $Message did not throw" }
}

$required = @(
    'scripts/feature-handoff-lib.ps1',
    'scripts/feature-handoff.ps1',
    'scripts/install-feature-handoff.ps1',
    'scripts/feature-handoff-status.ps1'
)
foreach ($relative in $required) {
    Assert-True (Test-Path (Join-Path $Root $relative)) "required feature handoff file missing: $relative"
}

. (Join-Path $Root 'scripts/feature-handoff-lib.ps1')

foreach ($fn in @(
    'New-FeatureHandoffState','Load-FeatureHandoffState','Save-FeatureHandoffState','Set-FeatureHandoffStage',
    'Get-FeatureHandoffKey','Test-ProductionWriteInProgress','Assert-FeatureChangedPathsSafe',
    'Get-WorktreeDiffSha256','Get-PreviewManifestIdentity','Freeze-PreviewManifestToOverlay',
    'Write-AcceptedPreviewRecord','Select-HandoffBuildPlan','Reconcile-ProductionState'
)) {
    Assert-True ([bool](Get-Command $fn -ErrorAction SilentlyContinue)) "feature handoff helper missing: $fn"
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhao-handoff-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $statePath = Join-Path $temp 'handoff.json'
    $state = New-FeatureHandoffState `
        -FeatureId 'arthur-adh-quickstart' `
        -AcceptedPreviewSourceSha ('a' * 40) `
        -AcceptedDiffSha256 ('b' * 64) `
        -PreviewManifestSha256 ('c' * 64) `
        -PreviewManifestPath 'manifest.json' `
        -PreviewEvidence @{ LIVE_PREVIEW='PASS'; ADGUARD_PREVIEW='PASS'; QUICKSTART_PREVIEW='PASS'; WIFI='VERIFIED_FROZEN' }

    Assert-Equal $state.current_stage 'PREVIEW_ACCEPTED' 'new state starts at PREVIEW_ACCEPTED'
    Assert-Equal $state.stage_status 'VERIFIED' 'accepted preview checkpoint must be verified'
    Assert-Equal $state.dispatch_key ("arthur-adh-quickstart:" + ('a' * 40)) 'dispatch key must bind feature and accepted source SHA'
    Save-FeatureHandoffState -State $state -StatePath $statePath
    $loaded = Load-FeatureHandoffState -StatePath $statePath
    Assert-Equal $loaded.dispatch_key $state.dispatch_key 'durable state must survive reload'

    Assert-True (Test-ProductionWriteInProgress -Stage 'FLASH_STARTED') 'FLASH_STARTED forbids redispatch'
    Assert-True (Test-ProductionWriteInProgress -Stage 'WAIT_DEVICE') 'WAIT_DEVICE forbids redispatch'
    Assert-True (Test-ProductionWriteInProgress -Stage 'REAL_DEVICE_VERIFY') 'REAL_DEVICE_VERIFY forbids redispatch'
    Assert-True (-not (Test-ProductionWriteInProgress -Stage 'CANDIDATE_VERIFIED')) 'Candidate verification alone is not a router write stage'

    foreach ($protected in @(
        'config/required-plugins.txt','config/arthur.config','config/arthur-known-good.lock',
        'production/known-good.json','files/etc/config/wireless','files/etc/config/network'
    )) {
        Assert-Throws { Assert-FeatureChangedPathsSafe -ChangedPaths @($protected) } 'PROTECTED|FROZEN|FORBIDDEN' "protected path must fail closed: $protected"
    }

    $manifestRoot = Join-Path $temp 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $manifestRoot 'staging') | Out-Null
    & git -C $manifestRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'TEST_FAIL: temporary manifest repository git init failed' }
    Set-Content -LiteralPath (Join-Path $manifestRoot 'staging/page.lua') -Value 'accepted-ui' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $manifestRoot 'staging/init.sh') -Value '#!/bin/sh' -Encoding UTF8
    $manifestPath = Join-Path $manifestRoot 'manifest.json'
    [ordered]@{
        schema_version = 1
        entries = @(
            [ordered]@{ local='staging/page.lua'; remote='/usr/lib/lua/luci/controller/Accepted.lua'; mode='0644' },
            [ordered]@{ local='staging/init.sh'; remote='/etc/init.d/Accepted'; mode='0755' }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $identity = Get-PreviewManifestIdentity -RepoRoot $manifestRoot -ManifestPath $manifestPath
    Assert-True ([string]$identity.manifest_sha256 -match '^[0-9a-f]{64}$') 'preview manifest must get SHA256 identity'
    Assert-Equal @($identity.entries).Count 2 'preview manifest identity must preserve both entries'
    $frozen = @(Freeze-PreviewManifestToOverlay -RepoRoot $manifestRoot -ManifestPath $manifestPath)
    Assert-Equal $frozen.Count 2 'both accepted files must be frozen'
    Assert-True (Test-Path (Join-Path $manifestRoot 'files/usr/lib/lua/luci/controller/Accepted.lua')) 'accepted LuCI byte must freeze into files overlay'
    Assert-True (Test-Path (Join-Path $manifestRoot 'files/etc/init.d/Accepted')) 'accepted init byte must freeze into files overlay'

    $plan = Select-HandoffBuildPlan -ChangedPaths @(
        'files/usr/lib/lua/luci/controller/Accepted.lua',
        'files/etc/init.d/Accepted',
        'production/accepted-preview/arthur-adh-quickstart.json'
    ) -KnownGoodLockChanged:$false
    Assert-Equal $plan.v3_mode 'rebuild_known_good' 'source-lock-preserving accepted overlay must use existing v3 production mode'
    Assert-True ([string]$plan.reason -match 'source-lock-preserving') 'build-plan decision must record its source identity reason'
    Assert-Throws { Select-HandoffBuildPlan -ChangedPaths @('config/arthur-known-good.lock') -KnownGoodLockChanged:$true } 'SOURCE_IDENTITY|KNOWN_GOOD|PROTECTED' 'known-good lock changes must not be silently dispatched'

    $prod = [pscustomobject]@{ run_id=123; stage='WAIT_DEVICE'; status='LIVE'; human_gate=$null }
    $reconciled = Reconcile-ProductionState -HandoffState $state -ProductionState $prod
    Assert-Equal $reconciled.current_stage 'PRODUCTION_RUNNING' 'WAIT_DEVICE maps to production running'
    Assert-True ($reconciled.suppress_dispatch -eq $true) 'WAIT_DEVICE must suppress duplicate dispatch'

    $released = Reconcile-ProductionState -HandoffState $state -ProductionState ([pscustomobject]@{ run_id=123; stage='PRODUCTION_RELEASED'; status='VERIFIED'; human_gate=$null })
    Assert-Equal $released.current_stage 'PRODUCTION_RELEASED' 'released production state maps to handoff terminal success'
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temp
}

$handoffText = Get-Content -Raw (Join-Path $Root 'scripts/feature-handoff.ps1')
$installerText = Get-Content -Raw (Join-Path $Root 'scripts/install-feature-handoff.ps1')
$statusText = Get-Content -Raw (Join-Path $Root 'scripts/feature-handoff-status.ps1')
$safePreviewText = Get-Content -Raw (Join-Path $Root 'scripts/live-preview-mature-safe.ps1')

Assert-Contains $handoffText 'arthur-update-v3.yml' 'handoff must dispatch the existing v3 Candidate workflow'
Assert-Contains $handoffText 'production-agent' 'handoff must attach to existing Production Agent state'
Assert-Contains $handoffText 'PRODUCTION_RELEASED' 'handoff must recognize sole successful terminal state'
Assert-Contains $handoffText 'dispatched_run_id' 'handoff must persist one-time dispatch identity'
Assert-Contains $installerText 'XinZhaoWrt-Arthur-Feature-Handoff' 'installer must create the persistent recovery task'
Assert-Contains $installerText 'Register-ScheduledTask' 'installer must use Windows Scheduled Task recovery'
Assert-True ($installerText -notmatch '(?i)NT AUTHORITY\\SYSTEM|LocalSystem|-UserId\s+["'']?SYSTEM') 'handoff task must not run as SYSTEM'
Assert-Contains $statusText 'FEATURE_HANDOFF_STAGE=' 'status script must expose durable stage'

Assert-Contains $safePreviewText 'FeatureId' 'safe preview must carry feature identity into handoff'
Assert-Contains $safePreviewText 'PauseAfterLivePreview' 'pause after preview must be explicit'
Assert-Contains $safePreviewText 'FEATURE_HANDOFF_STARTED=' 'successful preview must start the durable handoff by default'

foreach ($danger in @('push --force','push -f','reset --hard','clean -fdx')) {
    Assert-True ($handoffText.IndexOf($danger,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) "handoff must not use destructive git operation: $danger"
}

Write-Host 'FEATURE_HANDOFF_STATE_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_SOURCE_IDENTITY_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_NO_DUPLICATE_FLASH_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_RECOVERY_CONTRACT=PASS'