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

$workflowRunIndex = $deploy.IndexOf("@('workflow','run'",[System.StringComparison]::OrdinalIgnoreCase)
$acceptedIndex = $deploy.IndexOf("'REBUILD_DISPATCH_ACCEPTED'",[System.StringComparison]::OrdinalIgnoreCase)
$confirmDeadlineIndex = $deploy.IndexOf('$confirmDeadline',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($workflowRunIndex -ge 0) 'authenticated workflow_dispatch call must exist'
Assert-True ($acceptedIndex -gt $workflowRunIndex) 'dispatch acceptance must be persisted only after workflow_dispatch succeeds'
Assert-True ($confirmDeadlineIndex -gt $acceptedIndex) 'dispatch acceptance must be persisted before run-id confirmation begins'

Write-Host 'REBUILD_DISPATCH_AT_MOST_ONCE_CONTRACT=PASS'