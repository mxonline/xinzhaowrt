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
$ResumeStatePath = Join-Path $Root 'production\resume-state.json'
$RequestPath = Join-Path $Root 'production\release-request.json'
. (Join-Path $PSScriptRoot 'production-agent-release-mode.ps1')
$Policy = Get-ArthurProductionReleaseModePolicy -Path $PolicyPath
$ReleaseMode = [string]$Policy.mode
if ($ReleaseMode -ne 'RELEASE_ONLY') { throw "ARTHUR_RELEASE_ONLY_RUNTIME_MODE_MISMATCH=$ReleaseMode" }

function Read-ResumeState {
    if (-not (Test-Path -LiteralPath $ResumeStatePath -PathType Leaf)) { throw 'ARTHUR_RELEASE_ONLY_RESUME_STATE_MISSING' }
    try { return (Get-Content -LiteralPath $ResumeStatePath -Raw | ConvertFrom-Json) }
    catch { throw "ARTHUR_RELEASE_ONLY_RESUME_STATE_INVALID=$($_.Exception.Message)" }
}

function Read-ReleaseRequest {
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json) }
    catch { throw "ARTHUR_RELEASE_ONLY_REQUEST_INVALID=$($_.Exception.Message)" }
}

function Assert-ReleaseRequest($Request,$State) {
    if ($null -eq $Request) { return $false }
    if ($Request.PSObject.Properties.Name -notcontains 'authorized' -or $Request.authorized -ne $true) { return $false }
    if ([string]$Request.mode -ne 'RELEASE_ONLY') { throw 'ARTHUR_RELEASE_ONLY_REQUEST_MODE_MISMATCH' }
    if ([string]$Request.release_tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ARTHUR_RELEASE_ONLY_REQUEST_TAG_INVALID' }
    if ([string]$Request.version -ne ([string]$Request.release_tag).Substring(1)) { throw 'ARTHUR_RELEASE_ONLY_REQUEST_VERSION_TAG_MISMATCH' }
    if ($Request.PSObject.Properties.Name -contains 'execution_id' -and [string]$Request.execution_id) {
        if ([string]$State.execution_id -and [string]$Request.execution_id -ne [string]$State.execution_id) {
            throw 'ARTHUR_RELEASE_ONLY_REQUEST_EXECUTION_MISMATCH'
        }
    }
    if ($RunId -gt 0 -and $Request.PSObject.Properties.Name -contains 'run_id' -and [long]$Request.run_id -gt 0 -and [long]$Request.run_id -ne $RunId) {
        throw 'ARTHUR_RELEASE_ONLY_REQUEST_RUN_MISMATCH'
    }
    return $true
}

function Emit-Status($State,$Request) {
    [ordered]@{
        schema_version = '1.0'
        release_mode = $ReleaseMode
        unattended_release = [bool]$Policy.unattended_release
        automatic_flash = [bool]$Policy.automatic_flash
        execution_id = [string]$State.execution_id
        current_gate = [string]$State.current_gate
        status = [string]$State.status
        run_id = if ($State.production) { [long]$State.production.github_run_id } else { [long]0 }
        release_request_authorized = ($null -ne $Request -and $Request.PSObject.Properties.Name -contains 'authorized' -and $Request.authorized -eq $true)
        post_release_device_test = if ($State.PSObject.Properties.Name -contains 'post_release_device_test') { [string]$State.post_release_device_test } else { 'PENDING_INDEPENDENT' }
        next_action = if ([string]$State.status -eq 'PRODUCTION_RELEASED') { 'NONE' } else { 'CLOUD_RELEASE_ONLY_FINALIZER' }
    } | ConvertTo-Json -Depth 8
}

function Invoke-ReleaseOnlyObservation {
    $state = Read-ResumeState
    $request = Read-ReleaseRequest
    if ([string]$state.status -eq 'PRODUCTION_RELEASED') {
        Write-Host 'PRODUCTION_RELEASED=YES'
        Write-Host 'POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT'
        return
    }

    if (-not (Assert-ReleaseRequest -Request $request -State $state)) {
        Write-Host 'RELEASE_ONLY_WAITING_RELEASE_REQUEST=YES'
        Write-Host 'POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT'
        return
    }

    # RELEASE_ONLY deliberately has no rollback, SSH, upload, sysupgrade, reboot,
    # WAIT_DEVICE, or real-device verification implementation. GitHub Actions owns
    # Candidate -> Release Gate -> PRODUCTION_RELEASED; device testing is separate.
    Write-Host "RELEASE_ONLY_CLOUD_FINALIZER_OWNS_RELEASE=YES execution=$($state.execution_id)"
    Write-Host "RELEASE_ONLY_CURRENT_GATE=$($state.current_gate)"
    Write-Host 'POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT'
}

if ($Mode -eq 'Status') {
    $state = Read-ResumeState
    $request = Read-ReleaseRequest
    Emit-Status -State $state -Request $request
    exit 0
}

if ($Mode -eq 'RunOnce') {
    Invoke-ReleaseOnlyObservation
    exit 0
}

if ($PollSeconds -le 0) { $PollSeconds = 30 }
while ($true) {
    Invoke-ReleaseOnlyObservation
    $state = Read-ResumeState
    if ([string]$state.status -eq 'PRODUCTION_RELEASED') { exit 0 }
    Start-Sleep -Seconds $PollSeconds
}
