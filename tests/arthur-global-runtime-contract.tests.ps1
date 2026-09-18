$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Pin = 'ae014413f6d9302cada832683a359ecffe5a4942'
$ManifestPath = Join-Path $Root 'runtime-contract.json'
$WorkflowPath = Join-Path $Root '.github/workflows/arthur-global-runtime-contract.yml'

if (-not (Test-Path $ManifestPath)) { throw 'runtime-contract.json is required' }
$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
if ($Manifest.contract_version -ne 'global-runtime-v1') { throw 'contract_version mismatch' }
if ($Manifest.profile -ne 'arthur-v2') { throw 'Arthur must use arthur-v2 compatibility profile' }
if ($Manifest.bundles.Count -ne 1) { throw 'Arthur manifest must bind one active execution bundle' }
if ($Manifest.shared_validator_sha -ne $Pin) { throw 'manifest shared_validator_sha mismatch' }
$Bundle = $Manifest.bundles[0]
$State = Get-Content (Join-Path $Root 'production/resume-state.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$State.execution_id)) { throw 'Arthur resume state execution_id is required' }
if ($Bundle.execution_id -ne [string]$State.execution_id) { throw "Arthur execution_id mismatch: bundle=$($Bundle.execution_id) state=$($State.execution_id)" }
if ($Bundle.state -ne 'production/resume-state.json') { throw 'Arthur state path mismatch' }
if ($Bundle.events -ne 'production/firmware-events.jsonl') { throw 'Arthur event ledger path mismatch' }
$ExpectedEvidence = "production/evidence/$($State.execution_id)/index.json"
if ($Bundle.evidence -ne $ExpectedEvidence) { throw "Arthur evidence path mismatch: bundle=$($Bundle.evidence) expected=$ExpectedEvidence" }

$Workflow = Get-Content $WorkflowPath -Raw
if ($Workflow -notmatch 'mxonline/xinzhou-code-standard') { throw 'shared validator checkout missing' }
if ($Workflow -notmatch $Pin) { throw 'shared validator must be pinned to immutable merge SHA' }
if ($Workflow -notmatch 'tools/runtime_contract.py validate') { throw 'shared validator invocation missing' }
if ($Workflow -notmatch 'runtime-contract.json') { throw 'runtime manifest invocation missing' }

if ($State.PSObject.Properties.Name -contains 'state_revision') { throw 'Do not invent native state_revision in Arthur schema v2' }
if ($State.status -eq 'PRODUCTION_RELEASED') {
    if ($State.current_gate -ne 'PRODUCTION_RELEASED') { throw "Arthur current_gate must remain at the durable production terminal: $($State.current_gate)" }
    if ($State.next_action -ne 'NONE') { throw "Terminal Arthur state must not retain an actionable next step: $($State.next_action)" }
    if ($State.instruction_allowed -ne $false) { throw 'Terminal Arthur state must close instruction authorization' }
}
elseif ($State.status -eq 'RESUME_SAFE') {
    if ($State.instruction_allowed -ne $true) { throw 'Active fresh Arthur execution must permit authorized continuation' }
    if ([string]::IsNullOrWhiteSpace([string]$State.current_gate)) { throw 'Active fresh Arthur execution must expose current_gate' }
    if ([string]::IsNullOrWhiteSpace([string]$State.next_action) -or $State.next_action -eq 'NONE') { throw 'Active fresh Arthur execution must retain an actionable next step' }
}
else {
    throw "Arthur runtime contract does not recognize state status: $($State.status)"
}

Write-Host 'Arthur Global Runtime Contract integration: PASS'
