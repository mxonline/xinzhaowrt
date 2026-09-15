param(
    [ValidateSet('Resume','Status','RunOnce')]
    [string]$Mode = 'Resume',
    [long]$RunId = 0,
    [int]$PollSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PolicyPath = Join-Path $Root 'production\release-mode.json'
$ReleaseModeHelper = Join-Path $PSScriptRoot 'production-agent-release-mode.ps1'
$ReleaseOnlyRuntime = Join-Path $PSScriptRoot 'production-agent-release-only.ps1'
$LegacyRuntime = Join-Path $PSScriptRoot 'production-agent-flash-legacy.ps1'

foreach ($required in @($PolicyPath,$ReleaseModeHelper,$ReleaseOnlyRuntime,$LegacyRuntime)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "ARTHUR_PRODUCTION_AGENT_REQUIRED_FILE_MISSING=$required"
    }
}

. $ReleaseModeHelper
$Policy = Get-ArthurProductionReleaseModePolicy -Path $PolicyPath
$ReleaseMode = [string]$Policy.mode
$null = @(Get-ArthurProductionAgentStages -ReleaseMode $ReleaseMode)

$forward = @('-Mode',$Mode)
if ($RunId -gt 0) { $forward += @('-RunId',[string]$RunId) }
if ($PollSeconds -gt 0) { $forward += @('-PollSeconds',[string]$PollSeconds) }

if ($ReleaseMode -eq 'RELEASE_ONLY') {
    Write-Host 'ARTHUR_PRODUCTION_AGENT_MODE=RELEASE_ONLY'
    & $ReleaseOnlyRuntime @forward
    exit $LASTEXITCODE
}

if ($ReleaseMode -eq 'FLASH_AND_VERIFY') {
    Write-Host 'ARTHUR_PRODUCTION_AGENT_MODE=FLASH_AND_VERIFY'
    & $LegacyRuntime @forward
    exit $LASTEXITCODE
}

throw "ARTHUR_RELEASE_MODE_UNSUPPORTED=$ReleaseMode"
