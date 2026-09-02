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

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
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

# Discovery is a read-side safety gate. A failed/blank/unparseable run list must never be interpreted as "no matching run" and followed by another workflow_dispatch.
$listExitIndex = $deploy.IndexOf('$listExit = $LASTEXITCODE',[System.StringComparison]::OrdinalIgnoreCase)
$dispatchIndex = $deploy.IndexOf('if (-not $replacementRun) {',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($listExitIndex -ge 0) 'deploy must capture the replacement-run discovery exit code'
Assert-True ($dispatchIndex -gt $listExitIndex) 'replacement workflow dispatch must occur only after discovery'
$preDispatch = $deploy.Substring($listExitIndex, $dispatchIndex - $listExitIndex)
Assert-Contains $preDispatch '$discoverySucceeded' 'replacement-run discovery must track whether the read completed and parsed successfully'
Assert-Contains $preDispatch 'CURRENT_SOURCE_REBUILD_DISCOVERY_RETRY' 'failed replacement-run discovery must be explicitly retryable'
Assert-Contains $preDispatch 'continue' 'failed replacement-run discovery must fail closed before workflow_dispatch'
Assert-True ($preDispatch -match 'if\s*\(-not\s+\$discoverySucceeded\)') 'workflow_dispatch must be guarded by a fail-closed discovery success check'

Write-Host 'REBUILD_DISPATCH_ACK_CONTRACT=PASS'
