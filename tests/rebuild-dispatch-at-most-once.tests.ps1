$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$deploy = Get-Content -Raw (Join-Path $Root '.github/workflows/production-agent-deploy.yml')

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

Assert-Contains $deploy 'REBUILD_DISPATCH_ACCEPTED' 'successful workflow_dispatch must enter a durable accepted state before run-id confirmation'
Assert-Contains $deploy 'replacement_dispatch_accepted_at' 'accepted dispatch timestamp must be persisted'
Assert-Contains $deploy 'replacement_dispatch_source_sha' 'accepted dispatch must bind to the exact source SHA'
Assert-Contains $deploy 'CURRENT_SOURCE_REBUILD_CONFIRMING' 'accepted but unconfirmed dispatch must retry read-only discovery'
Assert-Contains $deploy '$skipAgentForAcceptedDispatch' 'accepted dispatch state must bypass Production Agent RunOnce so it cannot be rewritten back to REBUILD_REQUESTED'
Assert-Contains $deploy 'if (-not $skipAgentForAcceptedDispatch)' 'Production Agent invocation must be explicitly guarded by accepted dispatch state'
Assert-Contains $deploy '$dispatchAlreadyAccepted' 'rebuild handling must track whether workflow_dispatch has already been accepted'
Assert-Contains $deploy 'if ($dispatchAlreadyAccepted)' 'an accepted dispatch must take a read-only confirmation path instead of issuing another write'

$workflowRunIndex = $deploy.IndexOf("@('workflow','run'",[System.StringComparison]::OrdinalIgnoreCase)
$acceptedIndex = $deploy.IndexOf("'REBUILD_DISPATCH_ACCEPTED'",[System.StringComparison]::OrdinalIgnoreCase)
$confirmDeadlineIndex = $deploy.IndexOf('$confirmDeadline',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($workflowRunIndex -ge 0) 'authenticated workflow_dispatch call must exist'
Assert-True ($acceptedIndex -gt $workflowRunIndex) 'dispatch acceptance must be persisted only after workflow_dispatch succeeds'
Assert-True ($confirmDeadlineIndex -gt $acceptedIndex) 'dispatch acceptance must be persisted before run-id confirmation begins'

$loopIndex = $deploy.IndexOf('while ((Get-Date) -lt $deadline)',[System.StringComparison]::OrdinalIgnoreCase)
$skipIndex = $deploy.IndexOf('$skipAgentForAcceptedDispatch',[System.StringComparison]::OrdinalIgnoreCase)
$agentInvokeIndex = $deploy.IndexOf('& $pwsh -NoProfile -ExecutionPolicy Bypass -File $agent -Mode RunOnce -RunId $runId',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($loopIndex -ge 0 -and $skipIndex -gt $loopIndex -and $agentInvokeIndex -gt $skipIndex) 'accepted-state skip decision must happen before Production Agent RunOnce'

$acceptedGuardIndex = $deploy.IndexOf('if ($dispatchAlreadyAccepted)',[System.StringComparison]::OrdinalIgnoreCase)
$dispatchExecIndex = $deploy.IndexOf('$dispatchText = (& gh @dispatchArgs',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($acceptedGuardIndex -ge 0 -and $dispatchExecIndex -gt $acceptedGuardIndex) 'accepted dispatch guard must execute before any subsequent workflow_dispatch write'

Write-Host 'REBUILD_DISPATCH_AT_MOST_ONCE_CONTRACT=PASS'