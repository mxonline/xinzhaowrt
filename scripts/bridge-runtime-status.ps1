$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

Write-Host "BRIDGE_DIAG_MACHINE=$env:COMPUTERNAME"
Write-Host "BRIDGE_DIAG_RUNNER_USER=$env:USERDOMAIN\$env:USERNAME"

$repo = 'C:\Users\chenz\xinzhaowrt'
$orchestrator = Join-Path $repo 'ai_orchestrator'
$state = Join-Path $repo '.ai-orchestrator'
$codex = 'C:\Users\chenz\AppData\Roaming\Python\Python314\site-packages\codex_cli_bin\bin\codex.exe'

function Safe-TestPath([string]$Path) {
    try { return [bool](Test-Path $Path -ErrorAction Stop) }
    catch {
        Write-Host "BRIDGE_PATH_ACCESS_DENIED=$Path"
        return $false
    }
}

Write-Host "BRIDGE_ORIGINAL_REPO_EXISTS=$(Safe-TestPath $repo)"
Write-Host "BRIDGE_ORCHESTRATOR_EXISTS=$(Safe-TestPath $orchestrator)"
Write-Host "BRIDGE_STATE_DIR_EXISTS=$(Safe-TestPath $state)"
Write-Host "BRIDGE_CODEX_EXE_EXISTS=$(Safe-TestPath $codex)"

try {
    $taskCsv = & schtasks.exe /Query /FO CSV /V 2>&1
    $taskRows = @($taskCsv | ConvertFrom-Csv -ErrorAction SilentlyContinue)
    $matches = @($taskRows | Where-Object {
        $flat = ($_ | ConvertTo-Json -Compress -Depth 3)
        $flat -match '(?i)gpt|codex|bridge|orchestrator|xinzhao|C:\\Users\\chenz'
    })
    if ($matches.Count -eq 0) { Write-Host 'BRIDGE_SCHTASKS_MATCHES=NONE' }
    else {
        foreach ($row in $matches) {
            Write-Host "BRIDGE_SCHTASK=$(($row | ConvertTo-Json -Compress -Depth 3))"
        }
    }
} catch { Write-Host "BRIDGE_SCHTASKS_QUERY=FAILED $($_.Exception.Message)" }

try {
    $sessions = (& quser.exe 2>&1 | Out-String).Trim()
    if ($sessions) { Write-Host "BRIDGE_USER_SESSIONS=$($sessions -replace "`r?`n", ' | ')" }
} catch { Write-Host 'BRIDGE_USER_SESSIONS=UNAVAILABLE' }

$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$byProcId = @{}
foreach ($p in $all) { $byProcId[[int]$p.ProcessId] = $p }
$seeds = @($all | Where-Object {
    $_.ExecutablePath -and ($_.ExecutablePath -like 'C:\Users\chenz\*' -or $_.Name -match '(?i)codex|python')
})
if ($seeds.Count -eq 0) { Write-Host 'BRIDGE_PROCESSES=NONE' }
else {
    $seen = @{}
    foreach ($seed in $seeds) {
        $current = $seed
        for ($depth = 0; $depth -lt 5 -and $null -ne $current; $depth++) {
            $procId = [int]$current.ProcessId
            if (-not $seen.ContainsKey($procId)) {
                $seen[$procId] = $true
                $cmd = ''
                try { $cmd = [string]$current.CommandLine } catch {}
                if ($cmd.Length -gt 800) { $cmd = $cmd.Substring(0,800) }
                Write-Host "BRIDGE_PROCESS depth=$depth pid=$procId ppid=$($current.ParentProcessId) name=$($current.Name) path=$($current.ExecutablePath) cmd=$cmd"
            }
            $parentId = [int]$current.ParentProcessId
            if ($parentId -le 0 -or -not $byProcId.ContainsKey($parentId)) { break }
            $current = $byProcId[$parentId]
        }
    }
}

try {
    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '(?i)chenz|codex|bridge|orchestrator|xinzhao'
    })
    if ($services.Count -eq 0) { Write-Host 'BRIDGE_SERVICES=NONE' }
    else {
        foreach ($svc in $services) {
            Write-Host "BRIDGE_SERVICE name=$($svc.Name) state=$($svc.State) start=$($svc.StartName) path=$($svc.PathName)"
        }
    }
} catch { Write-Host "BRIDGE_SERVICES_QUERY=FAILED $($_.Exception.Message)" }

Write-Host 'BRIDGE_RUNTIME_DIAG=PASS'
