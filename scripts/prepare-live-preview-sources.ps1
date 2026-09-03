param(
    [ValidateSet('AdGuard','QuickStart','Both')]
    [string]$Feature = 'Both'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LockPath = Join-Path $Root 'production\mature-ui-sources.json'
if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    throw "MATURE_SOURCE_LOCK_MISSING path=$LockPath"
}

try {
    $Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json -Depth 20
} catch {
    throw "MATURE_SOURCE_LOCK_INVALID $($_.Exception.Message)"
}
if ([int]$Lock.schema_version -ne 1) {
    throw "MATURE_SOURCE_LOCK_SCHEMA_UNSUPPORTED actual=$($Lock.schema_version)"
}

function Invoke-Git([string[]]$Arguments, [switch]$AllowFailure) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { throw 'MATURE_SOURCE_GIT_MISSING' }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $git.Source @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = ($raw -join "`n").Trim()
    if (-not $AllowFailure -and $code -ne 0) {
        throw "MATURE_SOURCE_GIT_FAILED exit=$code args=$($Arguments -join ' ') output=$text"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Normalize-RepoPath([string]$Path) {
    return (($Path -replace '\\','/').TrimStart('/'))
}

function Get-UpstreamMode([string]$CloneRoot, [string]$GitPath) {
    $probe = Invoke-Git @('-C', $CloneRoot, 'ls-files', '-s', '--', (Normalize-RepoPath $GitPath))
    if ($probe.Output -notmatch '^(100644|100755)\s') {
        throw "MATURE_SOURCE_MODE_UNKNOWN path=$GitPath output=$($probe.Output)"
    }
    if ($Matches[1] -eq '100755') { return '0755' }
    return '0644'
}

function Add-ManifestFile(
    [System.Collections.Generic.List[object]]$Entries,
    [string]$CloneRoot,
    [string]$SourceSubdir,
    [string]$StagePackageRoot,
    [string]$PackageRelativeFile,
    [string]$Remote
) {
    $stageFile = Join-Path $StagePackageRoot ($PackageRelativeFile -replace '/','\')
    if (-not (Test-Path -LiteralPath $stageFile -PathType Leaf)) {
        throw "MATURE_SOURCE_FILE_MISSING path=$PackageRelativeFile"
    }
    $repoRelative = Normalize-RepoPath ([System.IO.Path]::GetRelativePath($Root, $stageFile))
    $gitPath = Normalize-RepoPath "$SourceSubdir/$PackageRelativeFile"
    $mode = Get-UpstreamMode $CloneRoot $gitPath
    $Entries.Add([pscustomobject]@{
        source = $repoRelative
        remote = $Remote
        mode = $mode
    })
}

$stagingRelative = Normalize-RepoPath ([string]$Lock.staging_root)
$stagingRoot = [System.IO.Path]::GetFullPath((Join-Path $Root ($stagingRelative -replace '/','\')))
$rootPrefix = $Root.TrimEnd('\') + '\'
if (-not $stagingRoot.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "MATURE_SOURCE_STAGING_OUTSIDE_REPO path=$stagingRoot"
}
if ($stagingRelative -ne 'sources/live-preview-mature') {
    throw "MATURE_SOURCE_STAGING_UNEXPECTED path=$stagingRelative"
}

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$wanted = switch ($Feature) {
    'AdGuard'   { @('adguardhome') }
    'QuickStart'{ @('quickstart') }
    'Both'      { @('adguardhome','quickstart') }
}

$entries = [System.Collections.Generic.List[object]]::new()
$resolvedSources = [System.Collections.Generic.List[object]]::new()

foreach ($source in @($Lock.sources)) {
    $name = [string]$source.name
    if ($name -notin $wanted) { continue }

    $repository = [string]$source.repository
    $ref = [string]$source.ref
    $subdir = Normalize-RepoPath ([string]$source.subdir)
    if ($ref -notmatch '^[0-9a-f]{40}$') { throw "MATURE_SOURCE_REF_NOT_PINNED name=$name ref=$ref" }
    if ($repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$') {
        throw "MATURE_SOURCE_REPOSITORY_UNSAFE name=$name repository=$repository"
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhaowrt-mature-$name-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        Invoke-Git @('clone','--filter=blob:none','--no-checkout','--quiet',$repository,$tempRoot) | Out-Null
        Invoke-Git @('-C',$tempRoot,'fetch','--depth','1','origin',$ref) | Out-Null
        Invoke-Git @('-C',$tempRoot,'checkout','--detach','--quiet',$ref) | Out-Null
        $actual = (Invoke-Git @('-C',$tempRoot,'rev-parse','HEAD')).Output.Trim()
        if ($actual -ne $ref) { throw "MATURE_SOURCE_REF_MISMATCH name=$name expected=$ref actual=$actual" }

        $packageRoot = Join-Path $tempRoot ($subdir -replace '/','\')
        if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
            throw "MATURE_SOURCE_SUBDIR_MISSING name=$name subdir=$subdir"
        }

        $stagePackage = Join-Path $stagingRoot $name
        New-Item -ItemType Directory -Path $stagePackage -Force | Out-Null
        Get-ChildItem -LiteralPath $packageRoot -Force | Copy-Item -Destination $stagePackage -Recurse -Force

        foreach ($mapping in @($source.mappings)) {
            $from = Normalize-RepoPath ([string]$mapping.source)
            $remoteBase = [string]$mapping.remote
            if (-not $remoteBase.StartsWith('/')) { throw "MATURE_SOURCE_REMOTE_NOT_ABSOLUTE name=$name remote=$remoteBase" }

            if ([string]$mapping.source -match '/$') {
                $mappingRoot = Join-Path $stagePackage ($from -replace '/','\')
                if (-not (Test-Path -LiteralPath $mappingRoot -PathType Container)) {
                    throw "MATURE_SOURCE_MAPPING_DIR_MISSING name=$name source=$from"
                }
                foreach ($file in @(Get-ChildItem -LiteralPath $mappingRoot -File -Recurse | Sort-Object FullName)) {
                    $suffix = Normalize-RepoPath ([System.IO.Path]::GetRelativePath($mappingRoot, $file.FullName))
                    $packageRelative = Normalize-RepoPath "$from/$suffix"
                    $remote = $remoteBase.TrimEnd('/') + '/' + $suffix
                    Add-ManifestFile $entries $tempRoot $subdir $stagePackage $packageRelative $remote
                }
            } else {
                Add-ManifestFile $entries $tempRoot $subdir $stagePackage $from $remoteBase
            }
        }

        $resolvedSources.Add([pscustomobject]@{ name=$name; repository=$repository; ref=$ref; subdir=$subdir })
        Write-Host "MATURE_SOURCE=PASS name=$name ref=$ref"
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($resolvedSources.Count -ne $wanted.Count) {
    throw "MATURE_SOURCE_SELECTION_INCOMPLETE expected=$($wanted.Count) actual=$($resolvedSources.Count)"
}
if ($entries.Count -eq 0) { throw 'MATURE_SOURCE_MANIFEST_EMPTY' }

$manifestPath = Join-Path $stagingRoot 'manifest.json'
$manifest = [ordered]@{
    schema_version = 1
    generated_from = @($resolvedSources)
    entries = @($entries)
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "MATURE_SOURCE_PREP=PASS feature=$Feature files=$($entries.Count)"
Write-Host "MATURE_SOURCE_MANIFEST=$manifestPath"
