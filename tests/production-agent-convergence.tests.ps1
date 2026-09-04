$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$agent=Get-Content -Raw (Join-Path $Root 'scripts/production-agent.ps1')
$gate=Get-Content -Raw (Join-Path $Root 'scripts/production-agent-convergence-lib.ps1')
$combined=$agent + "`n" + $gate

function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message missing='$Needle'"
    }
}
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "TEST_FAIL: $Message" } }

Assert-Contains $agent 'fast-safe-convergence-lib.ps1' 'Production Agent must reuse the convergence contract library'
Assert-Contains $agent 'production-agent-convergence-lib.ps1' 'Production Agent must load the true write-boundary convergence gate library'
Assert-Contains $combined 'release-convergence.json' 'Production Agent must read durable convergence evidence'
Assert-Contains $agent 'Assert-ProductionConvergenceBeforeFlash' 'sysupgrade path must have an explicit convergence hard gate'
Assert-Contains $gate 'Get-ConvergenceDispatchInputs' 'flash gate must bind exact firmware-input fingerprint'
Assert-Contains $gate 'Assert-FlashAllowed' 'flash gate must require resolved failure set, rootfs acceptance and no contract gap'
Assert-Contains $agent 'Invoke-VerifiedSysupgrade' 'standard sysupgrade remains the only production write mechanism'

$flashGateIndex=$agent.IndexOf('Assert-ProductionConvergenceBeforeFlash',[System.StringComparison]::OrdinalIgnoreCase)
$sysupgradeCallIndex=$agent.LastIndexOf('Invoke-VerifiedSysupgrade $state',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($flashGateIndex -ge 0 -and $sysupgradeCallIndex -ge 0) 'flash convergence gate and sysupgrade call must both exist'
Assert-Contains $combined 'flash_chain_id' 'Production Agent must persist one flash-chain identity'
Assert-Contains $gate 'FLASH_CHAIN_ALREADY_STARTED' 'same release chain must fail closed against a second sysupgrade'

Assert-Contains $gate 'release-convergence-manager.ps1' 'PostFlash verifier evidence must be ingested by the convergence manager'
Assert-Contains $gate 'IngestPostFlash' 'all PostFlash failures must be reconciled against the frozen failure set'
Assert-Contains $gate 'MarkMutation' 'repair after PostFlash failure must invalidate clean-release evidence before repair starts'
Assert-Contains $agent 'Assert-ProductionReleaseConvergence' 'GitHub Release path must have an explicit clean PostFlash hard gate'
Assert-Contains $gate 'Get-PostFlashReleaseDecision' 'release gate must use the shared clean PostFlash decision'
Assert-Contains $gate 'DENY_PRODUCTION_RELEASED' 'mutated/failed/contract-gap runtime must be denied release'
Assert-Contains $gate 'postflash_verification_result' 'release gate must require a persisted PASS from full REAL_DEVICE_VERIFY'

$releaseGateIndex=$agent.IndexOf('Assert-ProductionReleaseConvergence',[System.StringComparison]::OrdinalIgnoreCase)
$completeReleaseIndex=$agent.LastIndexOf('Complete-Release $state',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($releaseGateIndex -ge 0 -and $completeReleaseIndex -ge 0) 'clean PostFlash gate and release call must both exist'

Write-Host 'PRODUCTION_AGENT_CONVERGENCE_PREFLASH_LOCK=PASS'
Write-Host 'PRODUCTION_AGENT_SINGLE_FLASH_CHAIN_LOCK=PASS'
Write-Host 'PRODUCTION_AGENT_POSTFLASH_INGEST_LOCK=PASS'
Write-Host 'PRODUCTION_AGENT_CLEAN_RELEASE_LOCK=PASS'
