$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AgentPath = Join-Path $Root 'scripts\production-agent-flash-legacy.ps1'

function Assert-Contains { param([string]$Text,[string]$Needle,[string]$Message) if ($Text.IndexOf($Needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message (missing '$Needle')" } }
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "TEST_FAIL: $Message" } }

Assert-True (Test-Path -LiteralPath $AgentPath -PathType Leaf) 'legacy flash Production Agent must remain available for explicit compatibility mode'
$script = Get-Content -Raw $AgentPath
Assert-Contains $script 'arthur-evidence-index.ps1' 'Legacy Production Agent must load the evidence-index helper'
Assert-Contains $script 'execution_id' 'Legacy Production Agent state must carry execution identity'
Assert-Contains $script 'Add-ArthurEvidenceRecord' 'Legacy Production Agent must submit evidence records'
Assert-Contains $script 'ARTIFACT_MANIFEST' 'artifact verification must produce artifact evidence'
Assert-Contains $script 'FLASH_SAFETY_REPORT' 'legacy flash safety completion must produce safety evidence'
Assert-Contains $script 'FLASH_EVENT' 'legacy flash start must produce a durable write event'
Assert-Contains $script 'REAL_DEVICE_REPORT' 'legacy real-device verification must produce device evidence'
Assert-Contains $script 'GITHUB_RELEASE' 'legacy release completion must produce release evidence'
Assert-True (($script.IndexOf("'FLASH_EVENT'",[StringComparison]::OrdinalIgnoreCase)) -lt ($script.IndexOf('Invoke-VerifiedSysupgrade',[StringComparison]::OrdinalIgnoreCase))) 'FLASH_EVENT evidence must be written before legacy device-write entry'
Assert-Contains $script "if ([string]`$state.stage -eq 'FLASH_STARTED')" 'legacy crash recovery after FLASH_STARTED must remain explicit'
Assert-Contains $script 'Recovered after FLASH_STARTED; reconciling device state without a second write.' 'legacy crash recovery must never repeat the device write'

Write-Host 'PRODUCTION_AGENT_EVIDENCE_CONTRACT=PASS'