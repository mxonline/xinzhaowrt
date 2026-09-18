Set-StrictMode -Version Latest

function Invoke-ArthurControlPlaneDeviceObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('RELEASE_ONLY','FLASH_AND_VERIFY')][string]$ReleaseMode,
        [Parameter(Mandatory=$true)][scriptblock]$Action
    )

    if ($ReleaseMode -eq 'RELEASE_ONLY') {
        return [pscustomobject][ordered]@{
            skipped = $true
            reason = 'RELEASE_ONLY_DEVICE_OBSERVATION_NOT_REQUIRED'
            value = $null
        }
    }

    return [pscustomobject][ordered]@{
        skipped = $false
        reason = 'FLASH_AND_VERIFY_DEVICE_OBSERVATION_REQUIRED'
        value = (& $Action)
    }
}
