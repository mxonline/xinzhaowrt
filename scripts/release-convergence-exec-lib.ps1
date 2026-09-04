Set-StrictMode -Version Latest

if (Get-Variable -Name ReleaseConvergenceExecLoaded -Scope Script -ErrorAction SilentlyContinue) {
    return
}
$script:ReleaseConvergenceExecLoaded = $true

function Add-ConvergenceNoteProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,$Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Assert-ConvergenceCheckScriptTrusted {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$SourceRef = 'HEAD'
    )
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { throw "CONVERGENCE_CHECK_REPO_ROOT_MISSING=$RepoRoot" }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "CONVERGENCE_CHECK_SCRIPT_MISSING=$ScriptPath" }

    $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "CONVERGENCE_CHECK_UNTRUSTED_PATH=$resolved"
    }
    $relative = $resolved.Substring($prefix.Length).Replace('\','/')
    if (-not $relative -or $relative.StartsWith('../') -or $relative.Contains('/../')) {
        throw "CONVERGENCE_CHECK_UNTRUSTED_PATH=$relative"
    }

    $rawCommit = @(& git -C $root rev-parse --verify "$SourceRef^{commit}" 2>&1)
    $commitCode = $LASTEXITCODE
    $commit = ($rawCommit | ForEach-Object { [string]$_ }) -join "`n"
    $commit = $commit.Trim()
    if ($commitCode -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
        throw "CONVERGENCE_CHECK_SOURCE_REF_INVALID=$SourceRef"
    }

    $rawBlob = @(& git -C $root rev-parse "$SourceRef`:$relative" 2>&1)
    $blobCode = $LASTEXITCODE
    $blob = ($rawBlob | ForEach-Object { [string]$_ }) -join "`n"
    $blob = $blob.Trim()
    if ($blobCode -ne 0 -or $blob -notmatch '^[0-9a-f]{40}$') {
        throw "CONVERGENCE_CHECK_UNTRACKED_AT_SOURCE path=$relative source=$commit"
    }

    $rawWorking = @(& git -C $root hash-object -- $resolved 2>&1)
    $workingCode = $LASTEXITCODE
    $workingBlob = ($rawWorking | ForEach-Object { [string]$_ }) -join "`n"
    $workingBlob = $workingBlob.Trim()
    if ($workingCode -ne 0 -or $workingBlob -notmatch '^[0-9a-f]{40}$') {
        throw "CONVERGENCE_CHECK_WORKTREE_HASH_FAILED=$relative"
    }
    if ($workingBlob -ne $blob) {
        throw "CONVERGENCE_CHECK_WORKTREE_MISMATCH path=$relative source=$commit expected_blob=$blob actual_blob=$workingBlob"
    }

    return [pscustomobject][ordered]@{
        relative_path = $relative
        resolved_path = $resolved
        source_sha = $commit
        blob_sha = $blob
    }
}

function Invoke-ConvergenceEvidenceCheck {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArguments = @()
    )
    if (-not $CheckId.Trim()) { throw 'CONVERGENCE_CHECK_ID_REQUIRED' }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "CONVERGENCE_CHECK_SCRIPT_MISSING=$ScriptPath"
    }

    $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
    $raw = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $resolved @ScriptArguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $outputSha = Get-Sha256HexFromText -Text $output
    $record = [pscustomobject][ordered]@{
        check_id = $CheckId.Trim()
        script_path = $resolved
        exit_code = [int]$exitCode
        output_sha256 = $outputSha
        executed_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($exitCode -ne 0) {
        throw "CONVERGENCE_CHECK_FAILED check_id=$($record.check_id) exit=$exitCode output_sha256=$outputSha output=$output"
    }
    return $record
}

function Resolve-ConvergenceFailureWithCheck {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$RootCause,
        [Parameter(Mandatory)][string]$FirmwareSourceFix,
        [Parameter(Mandatory)][string]$PreflashCheckId,
        [Parameter(Mandatory)][string]$PreflashScriptPath,
        [string[]]$PreflashScriptArguments = @()
    )
    $executed = Invoke-ConvergenceEvidenceCheck -CheckId $PreflashCheckId -ScriptPath $PreflashScriptPath -ScriptArguments $PreflashScriptArguments
    $item = Set-FinalFailureResolution -FailureSet $Evidence `
        -CheckId $CheckId `
        -RootCause $RootCause `
        -FirmwareSourceFix $FirmwareSourceFix `
        -PreflashCheckId $PreflashCheckId `
        -PreflashPassed $true
    Add-ConvergenceNoteProperty -Object $item -Name 'preflash_output_sha256' -Value ([string]$executed.output_sha256)
    Add-ConvergenceNoteProperty -Object $item -Name 'preflash_executed_at' -Value ([string]$executed.executed_at)
    Add-ConvergenceNoteProperty -Object $item -Name 'preflash_script_path' -Value ([string]$executed.script_path)
    Add-ConvergenceNoteProperty -Object $Evidence -Name 'updated_at' -Value (Get-Date).ToUniversalTime().ToString('o')
    return $item
}

function Set-ConvergenceRootfsAcceptanceFromCheck {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$RootfsScriptPath,
        [Parameter(Mandatory)][string]$FirmwareInputFingerprint,
        [string[]]$RootfsScriptArguments = @()
    )
    $executed = Invoke-ConvergenceEvidenceCheck -CheckId 'rootfs.offline.acceptance' -ScriptPath $RootfsScriptPath -ScriptArguments $RootfsScriptArguments
    Set-ConvergenceRootfsAcceptance -Evidence $Evidence -Passed $true -FirmwareInputFingerprint $FirmwareInputFingerprint | Out-Null
    Add-ConvergenceNoteProperty -Object $Evidence -Name 'rootfs_check_id' -Value 'rootfs.offline.acceptance'
    Add-ConvergenceNoteProperty -Object $Evidence -Name 'rootfs_output_sha256' -Value ([string]$executed.output_sha256)
    Add-ConvergenceNoteProperty -Object $Evidence -Name 'rootfs_executed_at' -Value ([string]$executed.executed_at)
    Add-ConvergenceNoteProperty -Object $Evidence -Name 'rootfs_script_path' -Value ([string]$executed.script_path)
    return $Evidence
}
