$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptPath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw 'TEST_FAIL: Arthur Control Plane script is missing'
}

$script = Get-Content -Raw -LiteralPath $ScriptPath

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::Ordinal) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

$unsupportedReleaseListFields = "'tagName,isDraft,isPrerelease,publishedAt,targetCommitish'"
Assert-True ($script.IndexOf($unsupportedReleaseListFields,[System.StringComparison]::Ordinal) -lt 0) 'gh release list must not request unsupported targetCommitish JSON field'
Assert-Contains $script "'tagName,isDraft,isPrerelease,publishedAt'" 'gh release list must request only supported metadata fields'
Assert-Contains $script "'tagName,targetCommitish,assets,isPrerelease,isDraft,publishedAt'" 'gh release view must retain targetCommitish where GitHub CLI supports it'
Assert-Contains $script 'CONTROL_PLANE_FAIL=' 'Control Plane failures must be visible in Actions logs before exit'

Write-Host 'ARTHUR_CONTROL_PLANE_GH_CLI_CONTRACT=PASS'
