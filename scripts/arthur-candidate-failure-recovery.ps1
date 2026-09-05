[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$Workspace = $env:GITHUB_WORKSPACE,
    [string]$ControlRoot = '',
    [switch]$DecisionOnly,
    [string]$ResolverOutput = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-RepairResult([string]$Status,[long]$RunId = 0,[int]$ProcessId = 0,[string]$Detail = '') {
    $parts = @("CANDIDATE_FAILURE_REPAIR=$Status")
    if ($RunId -gt 0) { $parts += "run_id=$RunId" }
    if ($ProcessId -gt 0) { $parts += "pid=$ProcessId" }
    if ($Detail) { $parts += "detail=$Detail" }
    Write-Output ($parts -join ' ')
}

function Parse-Resolver([string]$Text) {
    $values = @{}
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $values
}

function Resolve-BashExecutable {
    foreach ($commandName in @('bash.exe','bash')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $gitCommand) { $gitCommand = Get-Command git -ErrorAction SilentlyContinue }
    if ($gitCommand -and $gitCommand.Source) {
        $gitCommandDir = Split-Path -Parent $gitCommand.Source
        $gitRoot = Split-Path -Parent $gitCommandDir
        if ($gitRoot) {
            # Git for Windows normally exposes Bash at 'bin\\bash.exe' or 'usr\\bin\\bash.exe'.
            $candidates.Add((Join-Path $gitRoot 'bin\\bash.exe'))
            $candidates.Add((Join-Path $gitRoot 'usr\\bin\\bash.exe'))
        }
    }

    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
        $candidates.Add((Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'))
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\bash.exe'))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\bash.exe'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return ''
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    throw 'CANDIDATE_FAILURE_REPAIR_WORKSPACE_MISSING'
}
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    throw "CANDIDATE_FAILURE_REPAIR_WORKSPACE_INVALID: $Workspace"
}

if ([string]::IsNullOrWhiteSpace($ControlRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'CANDIDATE_FAILURE_REPAIR_CONTROL_ROOT_MISSING'
    }
    $ControlRoot = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ControlPlane'
}
$ControlRoot = [IO.Path]::GetFullPath($ControlRoot)
$stateDir = Join-Path $ControlRoot 'state'
$markerPath = Join-Path $stateDir 'candidate-repair.json'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

if ([string]::IsNullOrWhiteSpace($ResolverOutput)) {
    $resolver = Join-Path $Workspace 'scripts\resolve-candidate-dedup.sh'
    if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
        throw "CANDIDATE_FAILURE_REPAIR_RESOLVER_MISSING: $resolver"
    }
    $bashExe = Resolve-BashExecutable
    if ([string]::IsNullOrWhiteSpace($bashExe)) {
        throw 'CANDIDATE_FAILURE_REPAIR_BASH_MISSING'
    }
    Write-Host "CANDIDATE_FAILURE_REPAIR_BASH=$bashExe"
    Push-Location $Workspace
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $ResolverOutput = (& $bashExe $resolver $Repository 'arthur-update-v3.yml' 'HEAD' 2>&1 | Out-String).Trim()
            $resolverCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
    }
    finally { Pop-Location }
    if ($resolverCode -ne 0) {
        throw "CANDIDATE_FAILURE_REPAIR_RESOLVER_FAILED: exit=$resolverCode output=$ResolverOutput"
    }
}

$decision = Parse-Resolver -Text $ResolverOutput
$action = if ($decision.ContainsKey('ACTION')) { [string]$decision['ACTION'] } else { '' }
if ($action -ne 'REPAIR_FAILED_RUN') {
    Write-RepairResult -Status 'NOT_REQUIRED' -Detail $(if ($action) { $action } else { 'NO_ACTION' })
    exit 0
}

$runId = 0L
if (-not $decision.ContainsKey('RUN_ID') -or -not [long]::TryParse([string]$decision['RUN_ID'], [ref]$runId) -or $runId -le 0) {
    throw 'CANDIDATE_FAILURE_REPAIR_INVALID_RUN_ID'
}

$existing = $null
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    try { $existing = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json }
    catch { $existing = $null }
}
if ($existing -and [long]$existing.run_id -eq $runId -and [int]$existing.pid -gt 0) {
    $live = Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue
    if ($live -and [string]$live.ProcessName -match '(?i)^pwsh$') {
        Write-RepairResult -Status 'ALREADY_RUNNING' -RunId $runId -ProcessId ([int]$existing.pid)
        exit 0
    }
}

if ($DecisionOnly) {
    Write-RepairResult -Status 'WOULD_START' -RunId $runId
    exit 0
}

$controller = Join-Path $Workspace 'scripts\ci-controller-v3.ps1'
if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) {
    throw "CANDIDATE_FAILURE_REPAIR_CONTROLLER_MISSING: $controller"
}
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwsh) { $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue }
if (-not $pwsh) { throw 'CANDIDATE_FAILURE_REPAIR_PWSH_MISSING' }

$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-Mode','Resume','-RunId',[string]$runId,'-Repository',$Repository,'-Branch','main','-Workflow','arthur-update-v3.yml')
$startArgs = @{
    FilePath = $pwsh.Source
    ArgumentList = $arguments
    WorkingDirectory = $Workspace
    PassThru = $true
}
$isWindowsHost = ([string]$env:OS -eq 'Windows_NT') -or ([string]$PSVersionTable.PSEdition -eq 'Desktop')
if ($isWindowsHost) { $startArgs['WindowStyle'] = 'Hidden' }
$proc = Start-Process @startArgs

$sourceSha = if ($decision.ContainsKey('SOURCE_SHA')) { [string]$decision['SOURCE_SHA'] } else { '' }
$fingerprint = if ($decision.ContainsKey('BUILD_FINGERPRINT')) { [string]$decision['BUILD_FINGERPRINT'] } else { '' }
[ordered]@{
    schema_version = 1
    status = 'RUNNING'
    run_id = $runId
    pid = [int]$proc.Id
    source_sha = $sourceSha
    build_fingerprint = $fingerprint
    controller = 'scripts/ci-controller-v3.ps1'
    mode = 'Resume'
    started_at = [DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $markerPath

Write-RepairResult -Status 'STARTED' -RunId $runId -ProcessId ([int]$proc.Id)
