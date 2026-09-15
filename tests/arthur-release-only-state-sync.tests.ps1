$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SyncPath = Join-Path $Root '.github/workflows/arthur-production-state-sync.yml'
$PromotionPath = Join-Path $Root '.github/workflows/promote-stable-v3.yml'

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
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}

Assert-True (Test-Path -LiteralPath $SyncPath -PathType Leaf) 'production state sync workflow must exist'
Assert-True (Test-Path -LiteralPath $PromotionPath -PathType Leaf) 'known-good promotion workflow must exist'
$sync = Get-Content -Raw $SyncPath
$promotion = Get-Content -Raw $PromotionPath

Assert-Contains $sync 'production/release-mode.json' 'State Sync must read the machine release mode'
Assert-Contains $sync 'RELEASE_ONLY' 'State Sync must have an explicit RELEASE_ONLY branch'
Assert-Contains $sync "resume['current_gate'] = 'RELEASE_GATE'" 'RELEASE_ONLY Artifact completion must route to RELEASE_GATE'
Assert-Contains $sync "intent['firmware_state']['next_stage'] = 'RELEASE_GATE'" 'operator projection must route Artifact to RELEASE_GATE'
Assert-Contains $sync 'gh release create' 'State Sync must own the RELEASE_ONLY GitHub Release write'
Assert-Contains $sync 'Complete-ArthurReleaseOnlyState' 'State Sync must reuse the existing release-only terminal state helper'
Assert-Contains $sync 'POST_RELEASE_DEVICE_TEST' 'State Sync must leave device acceptance pending and independent after Release'
Assert-Contains $sync 'firmware_execution_authorized' 'State Sync must verify durable execution authorization before release mutation'
Assert-Contains $sync 'FIRMWARE_RELEASE' 'State Sync must verify firmware release authorization scope'
Assert-Contains $sync 'FLASH_AND_VERIFY' 'legacy route must remain explicit compatibility rather than disappear'
Assert-NotContains $sync '/sbin/sysupgrade' 'cloud State Sync must never perform router sysupgrade'
Assert-NotContains $sync 'mtd write' 'cloud State Sync must never perform raw storage writes'

# Device-test/known-good responsibilities stay in the existing promotion lane.
Assert-Contains $promotion 'real-device-verification.json' 'Known-Good promotion must remain gated by durable real-device evidence'
Assert-Contains $promotion 'production/known-good.json' 'Known-Good promotion must remain the writer of the rollback baseline'
Assert-Contains $promotion 'device_verified' 'legacy/manual recovery promotion must retain an explicit device verification gate'

Write-Host 'ARTHUR_RELEASE_ONLY_STATE_SYNC_CONTRACT=PASS'
