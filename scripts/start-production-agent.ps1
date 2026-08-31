param([ValidateSet('Resume','RunOnce','Status')][string]$Mode='Resume')
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Agent=Join-Path $PSScriptRoot 'production-agent.ps1'
if (-not (Test-Path $Agent)) { throw "Production agent missing: $Agent" }
if ($Mode -eq 'Status') {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $Agent -Mode Status
    exit $LASTEXITCODE
}
$proc=Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Agent,'-Mode',$Mode) -WorkingDirectory $Root -WindowStyle Hidden -PassThru
Write-Host "PRODUCTION_AGENT_STARTED pid=$($proc.Id) mode=$Mode"
