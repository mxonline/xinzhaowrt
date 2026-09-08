$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateContract = Join-Path $Root 'scripts\arthur-state-contract.ps1'
$HandoffLib = Join-Path $Root 'scripts\feature-handoff-lib.ps1'

function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "TEST_FAIL: $Message" } }
function Assert-Equal { param($Actual,$Expected,[string]$Message) if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" } }

. $StateContract
. $HandoffLib

$sha = 'a' * 40
$state = New-FeatureHandoffState -FeatureId 'adh-cn' -AcceptedPreviewSourceSha $sha -AcceptedDiffSha256 ('b' * 64) -PreviewManifestSha256 ('c' * 64) -PreviewManifestPath 'output/preview.json' -PreviewEvidence @('LIVE_PREVIEW=PASS')
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$state.execution_id)) 'handoff must create an execution_id at preview acceptance'
Assert-True ([string]$state.execution_id -match '^arthur-adh-cn-aaaaaaa-\d{8}$') 'execution_id must bind feature and accepted source'
Assert-Equal ([string]$state.preview_observation.result) 'PASS' 'preview evidence must be recorded as an observation'
Assert-Equal ([string]$state.preview_observation.scope) 'LIVE_PREVIEW' 'preview observation must not claim production Gate PASS'

$temp = Join-Path ([IO.Path]::GetTempPath()) ("handoff-execution-{0}.json" -f ([guid]::NewGuid().ToString('N')))
try {
    Save-FeatureHandoffState -State $state -StatePath $temp
    $loaded = Load-FeatureHandoffState -StatePath $temp
    $expectedDispatchKey = "adh-cn:$sha"
    Assert-Equal ([string]$loaded.execution_id) ([string]$state.execution_id) 'restart/resume must preserve execution_id'
    Assert-Equal ([string]$loaded.dispatch_key) $expectedDispatchKey 'existing feature+accepted-sha idempotency key must remain unchanged'
}
finally { Remove-Item -Force -ErrorAction SilentlyContinue $temp }

Write-Host 'FEATURE_HANDOFF_EXECUTION_IDENTITY=PASS'
