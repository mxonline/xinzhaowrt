param(
    [switch]$Follow,
    [int]$PollSeconds = 10
)

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateFile = Join-Path $RepoRoot 'state\ci-v3-state.json'
$ControllerLog = Join-Path $RepoRoot 'output\controller-v3\controller.log'

function Show-State {
    Clear-Host
    Write-Host 'XinZhaoWrt Arthur v3 Persistent Auto-Repair Controller'
    Write-Host '====================================================='

    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
            $state | Format-List schema_version,status,stage,conclusion,run_id,repair_round,max_repair_rounds,update_mode,candidate_tag,branch,repository,message,updated_at
        }
        catch {
            Write-Warning "Could not parse state file: $($_.Exception.Message)"
            Get-Content -Raw -Path $StateFile
        }
    }
    else {
        Write-Host 'No v3 controller state file exists yet.'
    }

    if (Test-Path $ControllerLog) {
        Write-Host ''
        Write-Host 'Recent controller log:'
        Get-Content -Path $ControllerLog -Tail 30
    }
}

if ($Follow) {
    while ($true) {
        Show-State
        Start-Sleep -Seconds $PollSeconds
    }
}
else {
    Show-State
}
