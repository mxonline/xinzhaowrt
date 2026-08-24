param(
    [Parameter(Mandatory=$true)][string]$CandidateTag,
    [Parameter(Mandatory=$true)][string]$StableTag
)

$ErrorActionPreference = 'Stop'

Write-Host 'This helper intentionally does not perform device verification.'
Write-Host 'Run it only after JDCloud RE-SS-01 real-device verification has passed.'
Write-Host "Candidate: $CandidateTag"
Write-Host "Stable:    $StableTag"
Write-Host 'Use GitHub Actions workflow: Promote XinZhaoWrt Candidate to Stable'
Write-Host 'Set device_verified=true only after real-device checks pass.'
