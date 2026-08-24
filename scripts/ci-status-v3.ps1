param(
    [switch]$Follow,
    [int]$PollSeconds = 10
)

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateFile = Join-Path $RepoRoot 'state\ci-v3-state.json'
$LogFile = Join-Path $RepoRoot 'output\controller-v3\controller-v3.log'

function Show-V3State {
    Clear-Host
    Write-Host 'XinZhaoWrt OpenWrt v3 Controller'
    Write-Host '================================'
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -Raw $StateFile | ConvertFrom-Json
            $state | Format-List pipeline,status,stage,conclusion,run_id,repair_round,workflow,branch,repository,message,updated_at
        }
        catch {
            Write-Warning "Unable to parse state file: $($_.Exception.Message)"
            Get-Content $StateFile
        }
    }
    else {
        Write-Host "State file does not exist yet: $StateFile"
    }

    Write-Host ''
    Write-Host 'Recent controller log:'
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 20
    }
    else {
        Write-Host "Log file does not exist yet: $LogFile"
    }
}

do {
    Show-V3State
    if ($Follow) { Start-Sleep -Seconds $PollSeconds }
} while ($Follow)
