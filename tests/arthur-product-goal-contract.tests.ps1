$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ContractPath = Join-Path $Root 'production\product-goal-contract.json'
$GatePath = Join-Path $Root 'scripts\arthur-product-goal-contract.ps1'
$ProductTargetsPath = Join-Path $Root 'production\ARTHUR_PRODUCT_TARGETS.md'
$ReleasePolicyPath = Join-Path $Root 'production\release-policy.md'
$ProductionAgentConfigPath = Join-Path $Root 'production\production-agent.json'
$ControlPlaneGatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$LegacyAgentPath = Join-Path $Root 'scripts\production-agent-flash-legacy.ps1'
$FastPreflightPath = Join-Path $Root '.github\workflows\arthur-fast-preflight.yml'

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

foreach ($path in @(
    $ContractPath,$GatePath,$ProductTargetsPath,$ReleasePolicyPath,
    $ProductionAgentConfigPath,$ControlPlaneGatePath,$LegacyAgentPath,$FastPreflightPath,
    $BuildCheckPath,$VerifyProjectPath
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "required product-goal contract path missing: $path"
}

. $GatePath
$contract = Assert-ArthurProductGoalContract -Root $Root

Assert-True ([string]$contract.priority_class -eq 'HIGHEST') 'product goal must remain highest priority'
Assert-True ([string]$contract.goal.product_terminal -eq 'PRODUCT_GOAL_VERIFIED') 'product terminal must remain PRODUCT_GOAL_VERIFIED'
Assert-True ([string]$contract.goal.release_pipeline_terminal -eq 'PRODUCTION_RELEASED') 'release pipeline terminal must remain distinct'
Assert-True ($contract.execution_rules.build_success_is_not_product_success -eq $true) 'Build PASS must never equal product success'
Assert-True ($contract.execution_rules.release_success_is_not_product_success -eq $true) 'Release PASS must never equal product success'
Assert-True ($contract.execution_rules.live_validate_before_build_when_safe_and_applicable -eq $true) 'safe applicable live validation must precede wasteful build'
Assert-True ($contract.execution_rules.do_not_build_known_broken_behavior -eq $true) 'known-broken behavior must not be built'
Assert-True ($contract.openclash_adguardhome_coexistence.process_presence_is_insufficient -eq $true) 'PID coexistence alone must never pass coexistence'

$productTargets = Get-Content -Raw -LiteralPath $ProductTargetsPath
Assert-Contains $productTargets 'production/product-goal-contract.json' 'product target Source of Truth must bind the highest product-goal contract'
Assert-Contains $productTargets 'PRODUCT_GOAL_VERIFIED' 'product targets must name the real final product terminal'
Assert-Contains $productTargets 'PRODUCTION_RELEASED' 'product targets must distinguish the release pipeline terminal'

$releasePolicy = Get-Content -Raw -LiteralPath $ReleasePolicyPath
Assert-Contains $releasePolicy 'production/product-goal-contract.json' 'release policy must bind the highest product-goal contract'
Assert-Contains $releasePolicy 'PRODUCT_GOAL_VERIFIED' 'release policy must not confuse release completion with product completion'
Assert-Contains $releasePolicy 'PRODUCTION_RELEASED' 'release policy must retain the release-pipeline terminal'

$config = Get-Content -Raw -LiteralPath $ProductionAgentConfigPath | ConvertFrom-Json
Assert-True ([string]$config.product_goal_contract -eq 'production/product-goal-contract.json') 'production agent must point at the canonical product-goal contract'

$controlPlane = Get-Content -Raw -LiteralPath $ControlPlaneGatePath
Assert-Contains $controlPlane 'arthur-product-goal-contract.ps1' 'control plane must load the product-goal contract gate'
Assert-Contains $controlPlane 'Assert-ArthurProductGoalContract' 'control plane must execute the product-goal contract gate before routing'

$legacyAgent = Get-Content -Raw -LiteralPath $LegacyAgentPath
Assert-Contains $legacyAgent 'arthur-product-goal-contract.ps1' 'device/legacy production path must load the product-goal contract'
Assert-Contains $legacyAgent 'Assert-ArthurProductGoalContract' 'device/legacy production path must execute the product-goal contract gate'

$fastPreflight = Get-Content -Raw -LiteralPath $FastPreflightPath
Assert-Contains $fastPreflight 'arthur-product-goal-contract.tests.ps1' 'fast preflight must enforce the highest product-goal regression contract'

$verifyProject = Get-Content -Raw -LiteralPath $VerifyProjectPath
Assert-Contains $verifyProject 'check-product-goal-contract.py' 'every firmware build must pass the product-goal contract through verify-project'

$buildCheck = Get-Content -Raw -LiteralPath $BuildCheckPath
Assert-Contains $buildCheck 'ARTHUR_PRODUCT_GOAL_HIGHEST_PRIORITY=PASS' 'cross-platform build gate must emit machine evidence'

Write-Host 'ARTHUR_PRODUCT_GOAL_HIGHEST_PRIORITY=PASS'
Write-Host 'ARTHUR_PRODUCT_GOAL_MACHINE_EVIDENCE=PASS'
Write-Host 'ARTHUR_PRODUCT_GOAL_NO_STAGE_OVERRIDE=PASS'
