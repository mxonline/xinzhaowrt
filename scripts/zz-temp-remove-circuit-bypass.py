from pathlib import Path

path = Path('scripts/ci-controller-v3.ps1')
text = path.read_text(encoding='utf-8')
old = '''        if ($round -ge $MaxRepairRounds) {
            Write-ControllerLog "CIRCUIT_BREAKER: $MaxRepairRounds repair rounds reached with no terminal release. Switching to a clean GitHub runner execution instead of stopping."
            Reset-RepairChanges
            Sync-Branch
            $round = 0
            $currentRunId = Start-V3Run -RequestedMode $RequestedMode
            continue
        }

        $repairEvidenceRunId = $currentRunId
'''
new = '''        if ($round -ge $MaxRepairRounds) {
            Write-ControllerLog "CIRCUIT_BREAKER: $MaxRepairRounds repair rounds reached. Resetting the Codex round counter; replacement Candidate remains forbidden until exact build closure passes."
            Reset-RepairChanges
            Sync-Branch
            $round = 0
        }

        $repairEvidenceRunId = $currentRunId
'''
if old not in text:
    raise SystemExit('old circuit-breaker Candidate bypass block not found')
text = text.replace(old, new, 1)
path.write_text(text, encoding='utf-8')
