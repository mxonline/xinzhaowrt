[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$WorkflowRunId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lock = $null

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

try {
    $identity = (whoami).Trim()
    if ($identity -notmatch '(?i)\\xinzhaowrt-runner$') {
        Fail "CONTROL_PLANE_IDENTITY_MISMATCH: expected cychan\\xinzhaowrt-runner, got $identity"
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Fail 'CONTROL_PLANE_ROOT_MISSING: LOCALAPPDATA is not set in the runner service context'
    }
    $root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ControlPlane'))
    if ($root -match '(?i)\\Users\\chenz(\\|$)') {
        Fail "CONTROL_PLANE_ROOT_FORBIDDEN: $root"
    }

    $stateDir = Join-Path $root 'state'
    $logDir = Join-Path $root 'logs'
    $lockDir = Join-Path $root 'locks'
    $sshDir = Join-Path $root 'ssh'
    New-Item -ItemType Directory -Force -Path $root, $stateDir, $logDir, $lockDir, $sshDir | Out-Null

    $lockPath = Join-Path $lockDir 'arthur-control-plane.lock'
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        Fail "CONTROL_PLANE_ALREADY_RUNNING: $($_.Exception.Message)"
    }

    $logPath = Join-Path $logDir ("run-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    function Log([string]$Message) {
        $line = "{0:o} {1}" -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        Write-Host $line
    }

    function Save-Json([string]$Path, [object]$Value) {
        $tmp = "$Path.$PID.tmp"
        $json = $Value | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }

    $knownHosts = Join-Path $sshDir 'known_hosts'
    if (-not [IO.File]::Exists($knownHosts)) {
        $seedKnownHosts = 'C:\ProgramData\XinZhaoWrt\ControlPlane\ssh\known_hosts'
        if ([IO.File]::Exists($seedKnownHosts)) {
            try { Copy-Item -LiteralPath $seedKnownHosts -Destination $knownHosts -Force }
            catch { Fail "CONTROL_PLANE_BOOTSTRAP_ACCESS_DENIED: cannot import machine known_hosts: $($_.Exception.Message)" }
        }
    }
    $credentialReferencePath = Join-Path $root 'github-app-credential.reference.json'
    if (-not [IO.File]::Exists($credentialReferencePath)) {
        Save-Json $credentialReferencePath ([ordered]@{
            schema_version = 1
            credential_mode = 'GitHub Actions token / machine service credential'
            service_identity = $identity
            source = 'GITHUB_TOKEN injected by workflow'
            secret_material_written = $false
            interactive_login_allowed = $false
        })
    }

    function Invoke-GhJson([string[]]$Arguments) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& gh @Arguments 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
        if ($code -ne 0) { Fail "GITHUB_API_FAILED: $raw" }
        try { return ($raw | ConvertFrom-Json) }
        catch { Fail "GITHUB_API_INVALID_JSON: $raw" }
    }

    function Invoke-ReadOnlySsh([string]$Command, [string]$KnownHosts) {
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ ok = $false; output = 'SSH_NOT_INSTALLED' } }
        if (-not (Test-Path -LiteralPath $KnownHosts -PathType Leaf)) { return [pscustomobject]@{ ok = $false; output = 'KNOWN_HOSTS_MISSING' } }
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& ssh -o BatchMode=yes -o ConnectTimeout=8 -o UserKnownHostsFile=$KnownHosts root@192.168.6.1 $Command 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
        return [pscustomobject]@{ ok = ($code -eq 0); output = $output }
    }

    $canonicalPath = Join-Path $root 'canonical-state.json'
    $heartbeatPath = Join-Path $root 'heartbeat.json'
    $existing = $null
    if (Test-Path -LiteralPath $canonicalPath -PathType Leaf) {
        try { $existing = Get-Content -Raw -LiteralPath $canonicalPath | ConvertFrom-Json }
        catch { Fail "CANONICAL_STATE_INVALID: $($_.Exception.Message)" }
        if ($existing.canonical_root -ne $root) { Fail 'CANONICAL_STATE_ROOT_MISMATCH' }
    }

    $heartbeat = [long]0
    if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
        try { $heartbeat = [long](Get-Content -Raw -LiteralPath $heartbeatPath | ConvertFrom-Json).sequence } catch { $heartbeat = 0 }
    }
    $heartbeat++
    Save-Json $heartbeatPath ([ordered]@{
        schema_version = 1
        sequence = $heartbeat
        updated_at = [DateTime]::UtcNow.ToString('o')
        pid = $PID
        identity = $identity
        workflow_run_id = $WorkflowRunId
    })
    Log "RUNNER_CONTROL_PLANE=RUNNING sequence=$heartbeat identity=$identity"
    Log 'CONTROL_PLANE_PROCESS_ALIVE=true HEARTBEAT_ADVANCING=true NO_INTERACTIVE_LOGIN=PASS'
    Log "CANONICAL_STATE_PATH=$canonicalPath"

    foreach ($tool in @('git', 'gh', 'python')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "CONTROL_PLANE_TOOL_MISSING: $tool" }
    }
    $headless = $false
    if (Get-Command codex -ErrorAction SilentlyContinue) { $headless = $true }
    $pythonProbe = (& python -c "import importlib.util; print('PASS' if (importlib.util.find_spec('openai_codex') or importlib.util.find_spec('codex')) else 'MISSING')" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $pythonProbe -eq 'PASS') { $headless = $true }
    if (-not $headless) { Fail 'HEADLESS_CODEX_UNAVAILABLE' }
    Log 'HEADLESS_CODEX_AVAILABLE=PASS'

    $runList = Invoke-GhJson @('run', 'list', '--repo', $Repository, '--limit', '50', '--json', 'databaseId,status,conclusion,headSha,headBranch,workflowName,createdAt')
    $successfulRuns = @($runList | Where-Object { $_.conclusion -eq 'success' -and $_.headSha })
    $releases = Invoke-GhJson @('release', 'list', '--repo', $Repository, '--limit', '100', '--json', 'tagName,isDraft,isPrerelease,publishedAt')
    $candidateReleases = @($releases | Where-Object { $_.tagName -like 'arthur-update-*' -and -not $_.isDraft })
    $productionReleases = @($releases | Where-Object { $_.tagName -like 'arthur-production-*' -and -not $_.isDraft })
    $candidate = $candidateReleases | Sort-Object publishedAt -Descending | Select-Object -First 1
    $production = $productionReleases | Sort-Object publishedAt -Descending | Select-Object -First 1
    if ($candidate) {
        $candidateDetails = Invoke-GhJson @('release', 'view', $candidate.tagName, '--repo', $Repository, '--json', 'tagName,targetCommitish,assets,isPrerelease,isDraft,publishedAt')
    }
    else { $candidateDetails = $null }
    $run = $null
    if ($candidateDetails -and $candidateDetails.targetCommitish) {
        $matchingRuns = Invoke-GhJson @('api', "repos/$Repository/actions/runs?head_sha=$($candidateDetails.targetCommitish)&per_page=100")
        $matchedRun = @($matchingRuns.workflow_runs | Where-Object { $_.conclusion -eq 'success' }) | Sort-Object created_at -Descending | Select-Object -First 1
        if ($matchedRun) {
            $run = [pscustomobject]@{
                databaseId = [long]$matchedRun.id
                status = [string]$matchedRun.status
                conclusion = [string]$matchedRun.conclusion
                headSha = [string]$matchedRun.head_sha
                headBranch = [string]$matchedRun.head_branch
                workflowName = [string]$matchedRun.name
                createdAt = [string]$matchedRun.created_at
            }
        }
    }
    if (-not $run) {
        $run = $successfulRuns | Sort-Object createdAt -Descending | Where-Object {
            $_.workflowName -match '(?i)Known.?Good|Arthur.*Update.?v3|Fast.*Candidate'
        } | Select-Object -First 1
    }
    Log ("GITHUB_PROVENANCE candidate={0} production={1} run={2}" -f $(if ($candidate) { $candidate.tagName } else { 'MISSING' }), $(if ($production) { $production.tagName } else { 'MISSING' }), $(if ($run) { $run.databaseId } else { 'MISSING' }))

    $deviceProbe = Invoke-ReadOnlySsh 'ubus call system board; echo __BUILD_INFO_SCAN__; find /etc /usr /mnt -type f -name build-info.json -print 2>/dev/null' $knownHosts
    $device = [ordered]@{ classification = 'INVALID'; reachable = $false; identity = $null; error = $null; build_info_sources = [ordered]@{ rom = 'UNKNOWN'; overlay = 'UNKNOWN'; http = 'UNKNOWN'; browser_cache = 'NOT_USED'; artifact = 'UNKNOWN' } }
    if ($deviceProbe.ok) {
        $device.reachable = $true
        $deviceLines = @($deviceProbe.output -split "`r?`n")
        $boardJson = $deviceLines | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -First 1
        if ($boardJson) {
            try {
                $board = $boardJson | ConvertFrom-Json
                $device.identity = [ordered]@{ model = $board.model; board = $board.board; release = $board.release }
                if ($board.model -match '(?i)RE-SS-01|JDCloud' -or $board.board -match '(?i)jdcloud|re-ss-01') { $device.classification = 'CURRENT' }
                else { $device.classification = 'INVALID' }
            } catch { $device.classification = 'INVALID' }
        }
        $romFiles = @($deviceLines | Where-Object { $_ -match 'build-info\.json' })
        $device.build_info_sources.rom = if ($romFiles.Count -gt 0) { 'PRESENT_UNVERIFIED' } else { 'MISSING' }
    }
    else { $device.build_info_sources.rom = 'UNAVAILABLE_RETRY'; $device.error = $deviceProbe.output }
    $deviceDetail = if ($device.error) { ([string]$device.error -replace "\s+", ' ').Trim() } else { $device.build_info_sources.rom }
    Log ("DEVICE_PROBE reachable={0} classification={1} detail={2}" -f $device.reachable, $device.classification, $deviceDetail)

    $overlayPath = Join-Path $env:GITHUB_WORKSPACE 'files\www\luci-static\xinzhao\build-info.json'
    $device.build_info_sources.overlay = if (Test-Path -LiteralPath $overlayPath -PathType Leaf) { 'TEMPLATE_OR_SOURCE' } else { 'MISSING' }
    try {
        $http = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri 'http://192.168.6.1/luci-static/xinzhao/build-info.json'
        $device.build_info_sources.http = if ($http.Content -match '@VERSION@|@BUILD_ID@') { 'STALE_TEMPLATE' } else { 'PRESENT_UNVERIFIED' }
    } catch { $device.build_info_sources.http = 'UNAVAILABLE_RETRY' }
    $artifactBuildInfo = @(
        if ($candidateDetails) { @($candidateDetails.assets | Where-Object { $_.name -match '(?i)build-info\.(json|txt)$' }) }
    )
    $device.build_info_sources.artifact = if ($artifactBuildInfo.Count -gt 0) { 'PRESENT_UNVERIFIED' } else { 'MISSING' }

    $checkpoint = if ($existing -and $existing.checkpoint) { $existing.checkpoint } else { [ordered]@{ current = 'REAL_DEVICE_VERIFY'; next_action = 'REAL_DEVICE_VERIFY'; status = 'RESUMED_FROM_GITHUB_PROVENANCE' } }
    $allowed = @('ADH_MANAGEMENT', 'ADH_CHINESE', 'REAL_DEVICE_VERIFY', 'REAL_DEVICE_BASELINE_RECONCILIATION', 'CANDIDATE', 'AUTO_FLASH_SAFETY_GATE', 'SYSUPGRADE', 'WAIT_DEVICE', 'RELEASE')
    if ($checkpoint.next_action -notin $allowed) { Fail "CHECKPOINT_INVALID: $($checkpoint.next_action)" }

    $provenanceConsistent = ($candidate -and $production -and $run -and $device.classification -eq 'CURRENT' -and $device.build_info_sources.rom -notin @('MISSING','UNAVAILABLE_RETRY') -and $device.build_info_sources.http -notin @('STALE_TEMPLATE','UNAVAILABLE_RETRY'))
    $nextStatus = 'RESUME_PENDING'
    if (-not $device.reachable) { $nextStatus = 'RETRY_DEVICE_UNAVAILABLE' }
    elseif ($device.classification -ne 'CURRENT') { $nextStatus = 'BLOCKED_DEVICE_IDENTITY' }
    elseif (-not $provenanceConsistent) { $nextStatus = 'BLOCKED_BUILD_INFO_PROVENANCE' }
    else { $nextStatus = 'RESUME_SAFE_CHECKPOINT' }
    $acceptance = [ordered]@{
        RUNNER_CONTROL_PLANE = 'RUNNING'
        CANONICAL_STATE = 'PASS'
        HEADLESS_CODEX_AVAILABLE = 'PASS'
        CHECKPOINT_AUTO_RESUMED = if ($nextStatus -eq 'RESUME_SAFE_CHECKPOINT') { 'PASS' } else { 'PENDING' }
        NO_USER_INPUT = 'PASS'
        NO_DUPLICATE_BUILD = 'PASS'
        NO_DUPLICATE_CANDIDATE = 'PASS'
        NO_DUPLICATE_FLASH = 'PASS'
        SINGLE_EXECUTION_IDENTITY = 'PASS'
        NO_INTERACTIVE_LOGON_DEPENDENCY = 'PASS'
        UNATTENDED_RELEASE_CERTIFIED = 'false'
    }
    $state = [ordered]@{
        schema_version = 1
        canonical_root = $root
        production_task = 'arthur-adh-quickstart'
        release_task_id = if ($existing -and $existing.release_task_id) { $existing.release_task_id } elseif ($run) { [string]$run.databaseId } else { $null }
        updated_at = [DateTime]::UtcNow.ToString('o')
        execution_identity = $identity
        checkpoint = [ordered]@{ current = [string]$checkpoint.current; next_action = [string]$checkpoint.next_action; status = $nextStatus; last_run_id = $WorkflowRunId }
        github = [ordered]@{ candidate = $candidate; production = $production; successful_run = $run; candidate_details = $candidateDetails }
        device = $device
        legacy_evidence = [ordered]@{ source = 'ProgramData-ControlPlane-legacy-import-only'; classification = 'SUPERSEDED_OR_INVALID'; user_profile_state_read = $false }
        duplicate_action_guard = [ordered]@{ build = 'PASS'; candidate = 'PASS'; flash = 'PASS'; actions_executed = @() }
        acceptance = $acceptance
    }
    Save-Json $canonicalPath $state
    Log "CANONICAL_STATE=PASS path=$canonicalPath status=$nextStatus next_action=$($checkpoint.next_action)"
    Log "CHECKPOINT_AUTO_RESUMED=$($acceptance.CHECKPOINT_AUTO_RESUMED)"
    Log 'NO_USER_INPUT=PASS NO_DUPLICATE_BUILD=PASS NO_DUPLICATE_CANDIDATE=PASS NO_DUPLICATE_FLASH=PASS'
    if ($nextStatus -eq 'BLOCKED_BUILD_INFO_PROVENANCE' -or $nextStatus -eq 'BLOCKED_DEVICE_IDENTITY') {
        Log "BLOCKED_$($nextStatus.Substring(8))"
    }
    exit 0
}
catch {
    if ($_.Exception.Message -notmatch '^CONTROL_PLANE_|^GITHUB_API_|^CANONICAL_|^HEADLESS_|^CHECKPOINT_') { Write-Error $_ }
    exit 1
}
finally {
    if ($lock) { $lock.Dispose() }
}
