$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
if (-not (Test-Path $deployPath)) { throw 'TEST_FAIL: production-agent deploy workflow is missing' }
$deploy = Get-Content -Raw $deployPath

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

Assert-Contains $deploy 'actions: write' 'authenticated deploy must be allowed to dispatch the replacement Arthur build'
Assert-Contains $deploy 'REBUILD_DISPATCHING' 'rebuild request must enter an explicit dispatching state before acknowledgement'
Assert-Contains $deploy 'REBUILD_DISPATCHED' 'rebuild may only be acknowledged after GitHub returns a replacement run id'
Assert-Contains $deploy 'replacement_run_id' 'replacement run id must be persisted for later scheduled recovery'
Assert-Contains $deploy 'arthur-update-v3.yml' 'authenticated deploy must dispatch the current Arthur v3 build directly'
Assert-Contains $deploy "'workflow','run'" 'authenticated deploy must perform a real workflow_dispatch call'
Assert-Contains $deploy "'run','list'" 'authenticated deploy must confirm the replacement run exists before acknowledgement'
Assert-Contains $deploy 'headSha' 'replacement run confirmation must bind to the current source SHA'
Assert-Contains $deploy 'CURRENT_SOURCE_REBUILD_DISPATCHED=YES' 'deploy must expose confirmed rebuild dispatch evidence'
Assert-Contains $deploy 'CURRENT_SOURCE_REBUILD_DISPATCH_RETRY' 'dispatch failure must remain retryable rather than becoming a false acknowledgement'

Write-Host 'REBUILD_DISPATCH_ACK_CONTRACT=PASS'
