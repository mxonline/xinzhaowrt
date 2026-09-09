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
if ($Bundle.execution_id -ne 'arthur-final-release-5f41c4e-20260908') { throw 'Arthur execution_id mismatch' }
if ($Bundle.state -ne 'production/resume-state.json') { throw 'Arthur state path mismatch' }
if ($Bundle.events -ne 'production/firmware-events.jsonl') { throw 'Arthur event ledger path mismatch' }
if ($Bundle.evidence -ne 'production/evidence/arthur-final-release-5f41c4e-20260908/index.json') { throw 'Arthur evidence path mismatch' }

$Workflow = Get-Content $WorkflowPath -Raw
if ($Workflow -notmatch 'mxonline/xinzhou-code-standard') { throw 'shared validator checkout missing' }
if ($Workflow -notmatch $Pin) { throw 'shared validator must be pinned to immutable merge SHA' }
if ($Workflow -notmatch 'tools/runtime_contract.py validate') { throw 'shared validator invocation missing' }
if ($Workflow -notmatch 'runtime-contract.json') { throw 'runtime manifest invocation missing' }

$State = Get-Content (Join-Path $Root 'production/resume-state.json') -Raw | ConvertFrom-Json
if ($State.PSObject.Properties.Name -contains 'state_revision') { throw 'Do not invent native state_revision in Arthur schema v2' }
if ($State.current_gate -ne 'PRODUCTION_RELEASED') { throw "Arthur current_gate must remain at the durable production terminal: $($State.current_gate)" }
if ($State.next_action -ne 'NONE') { throw "Terminal Arthur state must not retain an actionable next step: $($State.next_action)" }
if ($State.status -ne 'PRODUCTION_RELEASED') { throw "Arthur state must preserve the durable production terminal: $($State.status)" }
if ($State.instruction_allowed -ne $false) { throw 'Terminal Arthur state must close instruction authorization' }

Write-Host 'Arthur Global Runtime Contract integration: PASS'
