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

Write-Host 'PASS: Arthur release-only PowerShell contract'
