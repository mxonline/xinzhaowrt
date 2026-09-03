param([string]$RuntimeRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if (-not $RuntimeRoot) { $RuntimeRoot=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff' }
$StatePath=Join-Path $RuntimeRoot 'handoff.json'
if (-not (Test-Path -LiteralPath $StatePath)) {
    Write-Host 'FEATURE_HANDOFF=IDLE'
    exit 0
}
try { $state=Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 30 }
catch { throw "FEATURE_HANDOFF_STATE_INVALID: $($_.Exception.Message)" }

$mergeSha=if ($state.PSObject.Properties.Name -contains 'merge_sha') { [string]$state.merge_sha } else { '' }
$runId=if ($state.PSObject.Properties.Name -contains 'dispatched_run_id') { [long]$state.dispatched_run_id } else { 0 }
$prod=if ($state.PSObject.Properties.Name -contains 'production_stage') { [string]$state.production_stage } else { '' }
$last=if ($state.PSObject.Properties.Name -contains 'last_error') { ([string]$state.last_error -replace '\s+',' ').Trim() } else { '' }
if ($last.Length -gt 500) { $last=$last.Substring(0,500) }

Write-Host "FEATURE_HANDOFF_STAGE=$($state.current_stage)"
Write-Host "FEATURE_HANDOFF_STATUS=$($state.stage_status)"
Write-Host "FEATURE_ID=$($state.feature_id)"
Write-Host "ACCEPTED_SOURCE_SHA=$($state.accepted_preview_source_sha)"
Write-Host "MERGE_SHA=$mergeSha"
Write-Host "RUN_ID=$runId"
Write-Host "PRODUCTION_STAGE=$prod"
Write-Host "LAST_ERROR=$last"
