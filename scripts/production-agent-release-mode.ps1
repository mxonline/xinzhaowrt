Set-StrictMode -Version Latest

$script:ArthurProductionReleaseModes = @('RELEASE_ONLY','FLASH_AND_VERIFY')

function Get-ArthurProductionReleaseModePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ARTHUR_RELEASE_MODE_POLICY_MISSING=$Path"
    }

    try {
        $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "ARTHUR_RELEASE_MODE_POLICY_INVALID=$($_.Exception.Message)"
    }

    $mode = [string]$policy.mode
    if ($script:ArthurProductionReleaseModes -notcontains $mode) {
        throw "ARTHUR_RELEASE_MODE_UNSUPPORTED=$mode"
    }

    if ($mode -eq 'RELEASE_ONLY') {
        if (-not [bool]$policy.unattended_release) {
            throw 'ARTHUR_RELEASE_ONLY_UNATTENDED_RELEASE_DISABLED'
        }
        if ([bool]$policy.automatic_flash) {
            throw 'ARTHUR_RELEASE_ONLY_AUTOMATIC_FLASH_FORBIDDEN'
        }
        if ([string]$policy.post_release_device_test -ne 'INDEPENDENT') {
            throw 'ARTHUR_RELEASE_ONLY_POST_RELEASE_DEVICE_TEST_NOT_INDEPENDENT'
        }
    }

    return $policy
}

function Get-ArthurProductionAgentStages {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ReleaseMode)

    $prefix = @(
        'REQUESTED',
        'ARTIFACT_METADATA_VERIFIED',
        'ARTIFACT_BYTES_VERIFIED',
        'CANDIDATE_VERIFIED'
    )
    $terminal = @('RELEASE_GATE','PRODUCTION_RELEASED')

    switch ($ReleaseMode) {
        'RELEASE_ONLY' {
            return @($prefix + $terminal)
        }
        'FLASH_AND_VERIFY' {
            return @($prefix + @(
                'REAL_DEVICE_BASELINE_GATE',
                'AUTO_FLASH_SAFETY_GATE',
                'FLASH_STARTED',
                'WAIT_DEVICE',
                'REAL_DEVICE_VERIFY'
            ) + $terminal)
        }
        default {
            throw "ARTHUR_RELEASE_MODE_UNSUPPORTED=$ReleaseMode"
        }
    }
}
