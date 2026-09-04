Set-StrictMode -Version Latest

function Get-ArthurIntentMember {
    param([object]$Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ArthurFirmwareExecutionPermission {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$OperatorIntent)

    $intentType = [string](Get-ArthurIntentMember $OperatorIntent 'intent_type')
    $scope = [string](Get-ArthurIntentMember $OperatorIntent 'authorization_scope')
    $authorized = Get-ArthurIntentMember $OperatorIntent 'firmware_execution_authorized'

    if ($authorized -ne $true) {
        return [pscustomobject]@{
            allowed = $false
            reason = 'FIRMWARE_EXECUTION_NOT_AUTHORIZED'
            intent_type = $intentType
            authorization_scope = $scope
        }
    }

    if ($scope -ne 'FIRMWARE_RELEASE' -or $intentType -ne 'EXECUTE_FIRMWARE') {
        return [pscustomobject]@{
            allowed = $false
            reason = 'AUTHORIZATION_SCOPE_MISMATCH'
            intent_type = $intentType
            authorization_scope = $scope
        }
    }

    return [pscustomobject]@{
        allowed = $true
        reason = 'FIRMWARE_EXECUTION_AUTHORIZED'
        intent_type = $intentType
        authorization_scope = $scope
    }
}

function Read-ArthurOperatorIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'OPERATOR_INTENT_MISSING'
    }
    try {
        $intent = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "OPERATOR_INTENT_INVALID_JSON: $($_.Exception.Message)"
    }

    if ([string](Get-ArthurIntentMember $intent 'project') -ne 'Arthur') {
        throw 'OPERATOR_INTENT_PROJECT_MISMATCH'
    }
    if ([string](Get-ArthurIntentMember $intent 'schema_version') -ne '1.0') {
        throw 'OPERATOR_INTENT_SCHEMA_UNSUPPORTED'
    }
    return $intent
}
