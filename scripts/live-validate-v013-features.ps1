param(
    [string]$Target = 'root@192.168.6.1',
    [string]$ExpectedVersion = '0.1.3',
    [string]$ExpectedBuildId = '33462873812'
)

$ErrorActionPreference = 'Stop'

# The old prebuild hot-deploy path is intentionally closed. It changed
# wireless UCI and could not prove the complete authenticated pages. The
# frozen Wi-Fi result is read-only evidence; real feature checks run only
# against the new Candidate with scripts/real-device-verify.ps1.
Write-Host 'WIFI=VERIFIED_FROZEN'
Write-Host 'ADGUARD_REAL_DEVICE=NOT_RUN'
Write-Host 'QUICKSTART_REAL_DEVICE=NOT_RUN'
Write-Host 'FIRMWARE_BUILD_ALLOWED=false'
Write-Host 'RELEASE_ALLOWED=false'
throw 'PREBUILD_HOTDEPLOY_DISABLED: generate a Candidate after implementation gates, then run real-device-verify.ps1 with an authenticated LuCI cookie.'
