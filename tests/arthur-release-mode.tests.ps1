$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/arthur-resume-state.ps1')

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "ASSERT_TRUE_FAILED: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) {
        throw "ASSERT_EQUAL_FAILED: $Message`nEXPECTED=$Expected`nACTUAL=$Actual"
    }
}

function Assert-Throws {
    param([scriptblock]$Action,[string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "ASSERT_THROWS_FAILED: $Message" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    Assert-True ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) $Message
}

function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    Assert-True ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) $Message
}

$policyPath = Join-Path $root 'production/release-mode.json'
Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'release mode policy must exist'
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
Assert-Equal ([string]$policy.schema_version) '1.0' 'release mode schema must be 1.0'
Assert-Equal ([string]$policy.mode) 'RELEASE_ONLY' 'new default mode must be RELEASE_ONLY'
Assert-True ([bool]$policy.unattended_release) 'unattended release must be enabled'
Assert-True (-not [bool]$policy.automatic_flash) 'automatic flash must be disabled'
Assert-Equal ([string]$policy.post_release_device_test) 'INDEPENDENT' 'post-release device test must be independent'
Assert-True ([bool]$policy.known_good_promotion_requires_post_release_device_test_pass) 'known-good promotion must require post-release device test PASS'
Assert-True ([bool]$policy.fail_closed_on_unknown) 'unknown release state must fail closed'

$order = @(Get-ArthurEffectivePhaseOrder -ReleaseMode 'RELEASE_ONLY')
Assert-True ($order -contains 'ARTIFACT') 'release-only order must include ARTIFACT'
Assert-True ($order -contains 'RELEASE_GATE') 'release-only order must include RELEASE_GATE'
Assert-True ($order -contains 'RELEASE') 'release-only order must include RELEASE'
Assert-True ($order -contains 'PRODUCTION_RELEASED') 'release-only order must include terminal'
Assert-True ($order -notcontains 'PRE_FLASH') 'release-only order must skip PRE_FLASH'
Assert-True ($order -notcontains 'AUTO_FLASH_SAFETY_GATE') 'release-only order must skip automatic flash safety gate'
Assert-True ($order -notcontains 'FLASH') 'release-only order must skip FLASH'
Assert-True ($order -notcontains 'WAIT_DEVICE') 'release-only order must skip WAIT_DEVICE'
Assert-True ($order -notcontains 'IDENTIFY') 'release-only order must skip device verification stages'
Assert-True ($order -notcontains 'SYSTEM_HEALTH') 'release-only order must skip post-flash system-health gate'

$legacy = @(Get-ArthurEffectivePhaseOrder -ReleaseMode 'FLASH_AND_VERIFY')
Assert-True ($legacy -contains 'PRE_FLASH') 'legacy compatibility mode must keep PRE_FLASH parseable'
Assert-True ($legacy -contains 'FLASH') 'legacy compatibility mode must keep FLASH parseable'
Assert-True ($legacy -contains 'SYSTEM_HEALTH') 'legacy compatibility mode must keep device verification parseable'

Assert-Throws { Get-ArthurEffectivePhaseOrder -ReleaseMode 'UNKNOWN' } 'unknown mode must fail closed'

$gates = @(
    [pscustomobject]@{ gate_id = 'ARTIFACT'; status = 'PASS' },
    [pscustomobject]@{ gate_id = 'PRE_FLASH'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'AUTO_FLASH_SAFETY_GATE'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'FLASH'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'WAIT_DEVICE'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'SYSTEM_HEALTH'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'RELEASE_GATE'; status = 'PENDING' },
    [pscustomobject]@{ gate_id = 'RELEASE'; status = 'PENDING' }
)
$next = Get-ArthurNextRequiredGate -Gates $gates -GateOrder $script:ArthurResumePhaseOrder
Assert-Equal ([string]$next.gate_id) 'RELEASE_GATE' 'default release-only resume selection must skip pending flash/device gates'

$legacyNext = Get-ArthurNextRequiredGate -Gates $gates -GateOrder $script:ArthurResumePhaseOrder -ReleaseMode 'FLASH_AND_VERIFY'
Assert-Equal ([string]$legacyNext.gate_id) 'PRE_FLASH' 'explicit legacy mode must preserve old flash traversal'

# Durable human-readable Source of Truth must agree with the machine route.
$agents = Get-Content -Raw (Join-Path $root 'AGENTS.md')
$livePreview = Get-Content -Raw (Join-Path $root 'knowledge/LIVE-PREVIEW.md')
$productTargets = Get-Content -Raw (Join-Path $root 'production/ARTHUR_PRODUCT_TARGETS.md')
foreach ($doc in @($agents,$livePreview,$productTargets)) {
    Assert-Contains $doc 'RELEASE_ONLY' 'release-control documents must name RELEASE_ONLY as the default production route'
    Assert-Contains $doc 'POST_RELEASE_DEVICE_TEST' 'release-control documents must keep device acceptance independent after Release'
}
Assert-NotContains $agents 'AUTO_FLASH_SAFETY_GATE` → Windows PowerShell → OpenSSH `ssh.exe` upload → remote SHA256 → previously verified Arthur `/sbin/sysupgrade` → `WAIT_DEVICE` → `REAL_DEVICE_VERIFY` → Release Gate' 'AGENTS must not define the legacy device-write chain as the default frozen production order'
Assert-NotContains $agents 'Only a newly built/flashed Candidate followed by formal `REAL_DEVICE_VERIFY=PASS` may enter Release Gate.' 'LIVE_PREVIEW guidance in AGENTS must not require flash before RELEASE_ONLY Release Gate'
Assert-NotContains $livePreview 'Candidate/build -> artifact/hash -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release' 'LIVE_PREVIEW must not route the default production path through device write before Release'
Assert-NotContains $livePreview 'Formal release still requires the deferred runtime checks plus `ADGUARD_REAL_DEVICE=PASS` after the Candidate is flashed.' 'AdGuard preview guidance must not make post-release device validation a RELEASE_ONLY release prerequisite'
Assert-NotContains $livePreview 'Formal release still requires `QUICKSTART_REAL_DEVICE=PASS` after Candidate flash.' 'QuickStart preview guidance must not make post-release device validation a RELEASE_ONLY release prerequisite'
Assert-NotContains $productTargets 'target diff -> implementation -> build -> artifact/hash checks -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> REAL_DEVICE_VERIFY -> Release Gate' 'product targets must not encode flash as a default Release prerequisite'

Write-Host 'PASS: Arthur release-only PowerShell contract'
