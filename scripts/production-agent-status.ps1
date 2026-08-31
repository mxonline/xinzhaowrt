$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$State=Join-Path $Root 'output\production-agent\state.json'
$Lock=Join-Path $Root 'output\production-agent\production-agent.lock'
if (-not (Test-Path $State)) {
    Write-Host 'PRODUCTION_AGENT_STATUS=NOT_INITIALIZED'
    exit 1
}
$data=Get-Content -Raw $State | ConvertFrom-Json
$pidValue=$null
$alive=$false
if (Test-Path $Lock) {
    try {
        $pidValue=[int](Get-Content -Raw $Lock)
        $alive=[bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
    } catch {}
}
[ordered]@{
    status=[string]$data.status
    stage=[string]$data.stage
    run_id=[long]$data.run_id
    candidate_sha256=[string]$data.candidate_sha256
    target=[string]$data.target
    human_gate=$data.human_gate
    agent_pid=$pidValue
    agent_alive=$alive
    updated_at=[string]$data.updated_at
} | ConvertTo-Json -Depth 6
