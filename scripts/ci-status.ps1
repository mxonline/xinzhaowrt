param(
    [switch]$Follow,
    [int]$PollSeconds = 10
)

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateFile = Join-Path $RepoRoot 'state\ci-state.json'
$ControllerLog = Join-Path $RepoRoot 'output\controller\controller.log'

function Show-State {
    Clear-Host
    Write-Host 'XinZhaoWrt Persistent CI Controller'
    Write-Host '=================================='
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
            $state | Format-List status,stage,conclusion,run_id,repair_round,branch,repository,message,updated_at
        }
        catch {
            Write-Warning "Could not parse state file: $($_.Exception.Message)"
            Get-Content -Raw -Path $StateFile
        }
    }
    else {
        Write-Host 'No controller state file exists yet.'
    }

    if (Test-Path $ControllerLog) {
        Write-Host ''
        Write-Host 'Recent controller log:'
        Get-Content -Path $ControllerLog -Tail 20
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
