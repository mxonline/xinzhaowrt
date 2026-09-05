from pathlib import Path

path = Path('scripts/ci-controller-v3.ps1')
text = path.read_text(encoding='utf-8')
if 'function Invoke-BuildClosurePreflight' in text:
    raise SystemExit('closure function already exists; refusing duplicate patch')

closure_function = r'''
function Invoke-BuildClosurePreflight {
    param([string]$RequestedMode,[int]$RepairRound)

    $closureWorkflow = 'arthur-fast-preflight.yml'
    $head = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    $started = [DateTime]::UtcNow

    Set-ControllerState -Status 'preflighting' -Stage 'build-closure' -Conclusion '' `
        -CurrentRunId 0 -RepairRound $RepairRound -CurrentUpdateMode $RequestedMode `
        -Message 'Running exact locked source/feed/package/defconfig closure before replacement Candidate.'

    Invoke-GhWithBackoff -Arguments @(
        'workflow','run',$closureWorkflow,
        '--repo',$Repository,
        '--ref',$Branch,
        '-f','build_closure=true',
        '-f',"update_mode=$RequestedMode"
    ) | Out-Null
    Write-ControllerLog "Triggered $closureWorkflow build_closure=true mode=$RequestedMode source=$head"

    $closureRun = $null
    while (-not $closureRun) {
        Start-Sleep 5
        $raw = Invoke-GhWithBackoff -Arguments @(
            'run','list','--repo',$Repository,'--workflow',$closureWorkflow,'--branch',$Branch,
            '--event','workflow_dispatch','--limit','30',
            '--json','databaseId,createdAt,status,conclusion,headSha,event'
        )
        $runs = @($raw | ConvertFrom-Json)
        $matches = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $runs) {
            if ([string]$entry.headSha -ne $head) { continue }
            try { $createdAt = [DateTime]::Parse([string]$entry.createdAt).ToUniversalTime() }
            catch { continue }
            if ($createdAt -lt $started.AddSeconds(-3)) { continue }
            $matches.Add($entry)
        }
        $closureRun = $matches |
            Sort-Object { [DateTime]::Parse([string]$_.createdAt) } -Descending |
            Select-Object -First 1
    }

    $closureRunId = [long]$closureRun.databaseId
    Write-ControllerLog "Build closure Run ID: $closureRunId source=$head"

    while ($true) {
        $raw = Invoke-GhWithBackoff -Arguments @(
            'run','view',[string]$closureRunId,'--repo',$Repository,
            '--json','status,conclusion,headSha,createdAt,updatedAt,url'
        )
        $view = $raw | ConvertFrom-Json
        $status = [string]$view.status
        $conclusion = if ($view.PSObject.Properties.Name -contains 'conclusion') { [string]$view.conclusion } else { '' }
        Write-ControllerLog "Build closure Run ${closureRunId}: status=$status conclusion=$conclusion"
        if ($status -eq 'completed') { break }
        Start-Sleep $PollSeconds
    }

    $runDir = Download-RunEvidence -Id $closureRunId -Failure
    $buildLog = Get-ChildItem -Path $runDir -Recurse -File -Filter 'build.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    $markerPass = $false
    if ($buildLog) {
        $markerPass = (Get-Content -Raw -LiteralPath $buildLog.FullName) -match '(?m)^BUILD_CLOSURE_PREFLIGHT=PASS\r?$'
    }

    $passed = ($conclusion -eq 'success' -and $markerPass)
    if ($passed) {
        Write-ControllerLog "BUILD_CLOSURE_PREFLIGHT=PASS run_id=$closureRunId source=$head"
    }
    else {
        Write-ControllerLog "BUILD_CLOSURE_PREFLIGHT=FAIL run_id=$closureRunId conclusion=$conclusion marker_pass=$markerPass source=$head"
    }

    return [pscustomobject]@{
        Passed = $passed
        RunId = $closureRunId
        RunDir = $runDir
        Conclusion = $(if ($markerPass) { $conclusion } else { 'closure-marker-missing' })
        SourceSha = $head
    }
}

'''
marker = 'function Get-LatestV3Run {'
if marker not in text:
    raise SystemExit('Get-LatestV3Run insertion marker missing')
text = text.replace(marker, closure_function + marker, 1)

start_marker = '        $runDir = Download-RunEvidence -Id $currentRunId -Failure\n'
end_marker = '        $currentRunId = Start-V3Run -RequestedMode $RequestedMode\n    }\n}\n\n$restartAfterRecoverable = $false'
process_start = text.find('function Process-V3Run')
start = text.find(start_marker, process_start)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit(f'repair block markers missing: start={start} end={end}')

replacement = r'''        $repairEvidenceRunId = $currentRunId
        $repairEvidenceDir = Download-RunEvidence -Id $currentRunId -Failure
        $repairEvidenceConclusion = $conclusion

        while ($true) {
            if ($round -ge $MaxRepairRounds) {
                Write-ControllerLog "CIRCUIT_BREAKER: $MaxRepairRounds repair rounds reached. Resetting the Codex round counter, but Candidate remains forbidden until build closure passes."
                Reset-RepairChanges
                Sync-Branch
                $round = 0
            }

            $round++
            Set-ControllerState -Status 'repairing' -Stage 'codex-auto-repair' -Conclusion $repairEvidenceConclusion `
                -CurrentRunId $repairEvidenceRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                -Message "Failure evidence is under Codex repair round $round/$MaxRepairRounds; replacement Candidate remains blocked by build closure."

            Sync-Branch
            Assert-CleanRepository
            $baselineBefore = Assert-KnownGoodBaseline
            $protectedBefore = Get-ProtectedHashes

            $action = 'retry'
            try {
                $decision = Invoke-CodexRepair -Id $repairEvidenceRunId -RunDir $repairEvidenceDir -Round $round -RequestedMode $RequestedMode
                $action = [string]$decision.decision
                Write-ControllerLog "Codex decision for evidence Run ${repairEvidenceRunId}: $action | $($decision.first_error) | $($decision.summary)"

                if ($action -eq 'blocked') {
                    Reset-RepairChanges
                    Write-ControllerLog "RECOVERABLE_CODEX_BLOCKED: ordinary Codex blocked result is not a human stop in the build/repair path. $($decision.first_error) - $($decision.summary)"
                    $action = 'retry'
                }

                if ($action -eq 'retry') {
                    $changes = @(Get-ChangedPaths)
                    if ($changes.Count -gt 0) { Reset-RepairChanges }
                    Assert-ProtectedFilesUnchanged -Before $protectedBefore
                    Write-ControllerLog 'Failure classified as retry/reacquire-evidence; validating exact build closure before any Candidate retry.'
                }
                elseif ($action -eq 'repaired') {
                    $changed = @(Assert-RepairSafe -ProtectedBefore $protectedBefore -BaselineBefore $baselineBefore)
                    Commit-And-PushRepair -ChangedPaths $changed -Round $round -FailedRunId $repairEvidenceRunId | Out-Null
                    Sync-Branch
                }
                else {
                    Reset-RepairChanges
                    Write-ControllerLog "RECOVERABLE_CODEX_DECISION: unsupported decision=$action; falling back to clean retry."
                    $action = 'retry'
                }
            }
            catch {
                Reset-RepairChanges
                Write-ControllerLog "RECOVERABLE_REPAIR_HANDLER: $($_.Exception.Message); exact build closure will decide whether another Candidate is allowed."
                $action = 'retry'
            }

            $closure = Invoke-BuildClosurePreflight -RequestedMode $RequestedMode -RepairRound $round
            if ($closure.Passed) {
                Write-ControllerLog "BUILD_CLOSURE_PASS_ALLOW_CANDIDATE run_id=$($closure.RunId) source=$($closure.SourceSha)"
                break
            }

            Write-ControllerLog "BUILD_CLOSURE_FAILED_CONTINUE_REPAIR run_id=$($closure.RunId) conclusion=$($closure.Conclusion); replacement Candidate remains blocked."
            $repairEvidenceRunId = [long]$closure.RunId
            $repairEvidenceDir = [string]$closure.RunDir
            $repairEvidenceConclusion = [string]$closure.Conclusion
        }

        Set-ControllerState -Status 'retrying' -Stage 'trigger-next-run' -Conclusion '' `
            -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
            -Message 'Exact build closure passed; replacement Arthur v3 Candidate is now allowed.'

        $currentRunId = Start-V3Run -RequestedMode $RequestedMode
'''
text = text[:start] + replacement + text[end + len('        $currentRunId = Start-V3Run -RequestedMode $RequestedMode\n'):]
path.write_text(text, encoding='utf-8')
