param(
    [long]$RunId = 0,
    [long]$ArtifactId = 0,
    [string]$ArtifactName = '',
    [string]$ExpectedCandidateSha256 = '',
    [long]$ExpectedCandidateSize = 0,
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$Destination = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Config = Get-Content -Raw (Join-Path $Root 'production\production-agent.json') | ConvertFrom-Json
if ($RunId -le 0) { $RunId = [long]$Config.bootstrap.run_id }
if ($ArtifactId -le 0) { $ArtifactId = [long]$Config.bootstrap.artifact_id }
if (-not $ArtifactName) { $ArtifactName = [string]$Config.bootstrap.artifact_name }
if (-not $ExpectedCandidateSha256) { $ExpectedCandidateSha256 = [string]$Config.bootstrap.candidate_sha256 }
if ($ExpectedCandidateSize -le 0) { $ExpectedCandidateSize = [long]$Config.bootstrap.candidate_size }
if (-not $Destination) { $Destination = Join-Path $Root 'output\production-agent\artifact' }

$OutRoot = Join-Path $Root 'output\production-agent'
$MetadataPath = Join-Path $OutRoot 'artifact-metadata.json'
$ManifestPath = Join-Path $OutRoot 'candidate-manifest.json'
$LogPath = Join-Path $OutRoot 'artifact-fetch.log'
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

function Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function Invoke-Gh([string[]]$Args,[switch]$AllowFailure) {
    $text = (& gh @Args 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) { throw "gh $($Args -join ' ') failed ($code): $text" }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# Production authentication contract: use the current Windows user's persistent GitHub CLI credential store.
# Literal command retained for static contract visibility: gh auth status --hostname github.com
$auth = Invoke-Gh @('auth','status','--hostname','github.com') -AllowFailure
if ($auth.ExitCode -ne 0) {
    Log 'NEW_CREDENTIAL_PROVISIONING: gh auth status failed; artifact fetch stopped without rebuild.'
    [pscustomobject]@{ status='BLOCKED'; human_gate='NEW_CREDENTIAL_PROVISIONING'; run_id=$RunId; artifact_id=$ArtifactId; rebuild=$false } | ConvertTo-Json -Depth 6
    exit 41
}

$api = Invoke-Gh @('api',"repos/$Repository/actions/runs/$RunId/artifacts")
$payload = $api.Output | ConvertFrom-Json
$artifact = @($payload.artifacts | Where-Object { [long]$_.id -eq $ArtifactId -and [string]$_.name -eq $ArtifactName }) | Select-Object -First 1
if (-not $artifact) { throw "Artifact identity not found: run=$RunId id=$ArtifactId name=$ArtifactName" }
if ($artifact.expired -eq $true) { throw "Artifact is expired: id=$ArtifactId" }

$metadata = [ordered]@{
    status = 'ARTIFACT_METADATA_VERIFIED'
    repository = $Repository
    run_id = $RunId
    artifact_id = [long]$artifact.id
    artifact_name = [string]$artifact.name
    artifact_size_in_bytes = [long]$artifact.size_in_bytes
    artifact_digest = [string]$artifact.digest
    expired = [bool]$artifact.expired
    verified_at = (Get-Date).ToString('o')
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $MetadataPath
Log 'ARTIFACT_METADATA_VERIFIED'

$existing = Get-ChildItem -Path $Destination -Recurse -File -Filter '*sysupgrade.bin' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    $existingHash = (Get-FileHash -Algorithm SHA256 $existing.FullName).Hash.ToLowerInvariant()
    if (($ExpectedCandidateSha256 -and $existingHash -eq $ExpectedCandidateSha256.ToLowerInvariant()) -and (($ExpectedCandidateSize -le 0) -or $existing.Length -eq $ExpectedCandidateSize)) {
        Log "ARTIFACT_BYTES_VERIFIED reuse=$($existing.FullName)"
    } else {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Destination
        $existing = $null
    }
}

if (-not $existing) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $delays = @($Config.artifact_retry_seconds)
    $downloaded = $false
    for ($i=0; $i -lt $delays.Count; $i++) {
        # Production download contract: gh run download <run> --repo <repo> --name <artifact> --dir <destination>
        $dl = Invoke-Gh @('run','download',[string]$RunId,'--repo',$Repository,'--name',$ArtifactName,'--dir',$Destination) -AllowFailure
        if ($dl.ExitCode -eq 0) { $downloaded = $true; break }
        $msg = [string]$dl.Output
        if ($msg -match '(?i)authentication|not logged|token.*expired|bad credentials|HTTP 401') {
            Log 'NEW_CREDENTIAL_PROVISIONING: authenticated artifact download rejected; no rebuild.'
            exit 41
        }
        if ($msg -notmatch '(?i)rate limit|HTTP 403|HTTP 5\d\d|timeout|timed out|EOF|connection reset|connection refused') {
            throw "Artifact download failed deterministically: $msg"
        }
        $delay = [int]$delays[$i]
        Log "Transient artifact download failure; retry same run/artifact after ${delay}s. $msg"
        Start-Sleep -Seconds $delay
    }
    if (-not $downloaded) { throw "Artifact download retries exhausted for same run $RunId; rebuild prohibited." }
    $existing = Get-ChildItem -Path $Destination -Recurse -File -Filter '*sysupgrade.bin' -ErrorAction SilentlyContinue | Select-Object -First 2
    if (@($existing).Count -ne 1) { throw "Expected exactly one sysupgrade.bin, found $(@($existing).Count)" }
    $existing = @($existing)[0]
}

if (-not $existing -or $existing.Length -le 0) { throw 'Downloaded candidate is missing or empty.' }
$hash = (Get-FileHash -Algorithm SHA256 $existing.FullName).Hash.ToLowerInvariant()
if ($ExpectedCandidateSha256 -and $hash -ne $ExpectedCandidateSha256.ToLowerInvariant()) { throw "Candidate SHA256 mismatch expected=$ExpectedCandidateSha256 actual=$hash" }
if ($ExpectedCandidateSize -gt 0 -and $existing.Length -ne $ExpectedCandidateSize) { throw "Candidate size mismatch expected=$ExpectedCandidateSize actual=$($existing.Length)" }

$manifest = [ordered]@{
    status = 'ARTIFACT_BYTES_VERIFIED'
    candidate_status = 'CANDIDATE_VERIFIED'
    repository = $Repository
    run_id = $RunId
    artifact_id = $ArtifactId
    artifact_name = $ArtifactName
    candidate_path = $existing.FullName
    candidate_filename = $existing.Name
    candidate_size = [long]$existing.Length
    candidate_sha256 = $hash
    target = [string]$Config.target
    profile = [string]$Config.profile
    source_sha = [string]$Config.bootstrap.source_sha
    verified_at = (Get-Date).ToString('o')
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $ManifestPath
Log "ARTIFACT_BYTES_VERIFIED candidate=$($existing.Name) sha256=$hash"
$manifest | ConvertTo-Json -Depth 8
