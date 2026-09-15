Set-StrictMode -Version Latest

$script:ArthurGateStatuses = @(
    'PENDING',
    'RUNNING',
    'PASS',
    'FAIL',
    'BLOCKED',
    'STALE',
    'SKIPPED'
)

function Get-ArthurStateMember {
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

function Get-ArthurStatePropertyNames {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties.Name)
}

function Get-ArthurStateSha256 {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-ArthurExecutionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TaskSlug,
        [Parameter(Mandatory=$true)][string]$AcceptedSourceSha,
        [Parameter(Mandatory=$true)][datetime]$Date
    )

    $source = $AcceptedSourceSha.Trim().ToLowerInvariant()
    if ($source -notmatch '^[0-9a-f]{40,64}$') { throw "ARTHUR_EXECUTION_SOURCE_SHA_INVALID=$AcceptedSourceSha" }

    $slug = $TaskSlug.Trim().ToLowerInvariant()
    $slug = [regex]::Replace($slug,'[^a-z0-9]+','-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { throw 'ARTHUR_EXECUTION_TASK_SLUG_INVALID' }

    return ('arthur-{0}-{1}-{2}' -f $slug,$source.Substring(0,7),$Date.ToString('yyyyMMdd'))
}

function Get-ArthurRequirementDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$RequirementText)
    return (Get-ArthurStateSha256 -Text $RequirementText)
}

function New-ArthurGateRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$GateId,
        [Parameter(Mandatory=$true)][string]$RequirementRef,
        [Parameter(Mandatory=$true)][string]$RequirementDigest,
        [Parameter(Mandatory=$true)][ValidateSet('PENDING','RUNNING','PASS','FAIL','BLOCKED','STALE','SKIPPED')][string]$Status,
        [object]$Subject = $null,
        [string[]]$EvidenceRefs = @(),
        [bool]$Inherited = $false,
        [string]$InheritedFrom = '',
        [string]$VerifiedAt = ''
    )

    if ([string]::IsNullOrWhiteSpace($GateId)) { throw 'ARTHUR_GATE_ID_MISSING' }
    if ([string]::IsNullOrWhiteSpace($RequirementRef)) { throw "ARTHUR_GATE_REQUIREMENT_REF_MISSING=$GateId" }
    $digest = $RequirementDigest.Trim().ToLowerInvariant()
    if ($digest -notmatch '^[0-9a-f]{64}$') { throw "ARTHUR_GATE_REQUIREMENT_DIGEST_INVALID=$GateId" }

    $refs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($Status -eq 'PASS') {
        $directEvidence = $refs.Count -gt 0
        $inheritedEvidence = $Inherited -and -not [string]::IsNullOrWhiteSpace($InheritedFrom)
        if (-not $directEvidence -and -not $inheritedEvidence) {
            throw "ARTHUR_GATE_PASS_WITHOUT_EVIDENCE=$GateId"
        }
    }
    if ($Inherited -and [string]::IsNullOrWhiteSpace($InheritedFrom)) {
        throw "ARTHUR_GATE_INHERITANCE_SOURCE_MISSING=$GateId"
    }

    return [pscustomobject][ordered]@{
        gate_id = $GateId
        status = $Status
        requirement_ref = $RequirementRef
        requirement_digest = $digest
        subject = $(if ($null -eq $Subject) { [pscustomobject]@{} } else { $Subject })
        evidence_refs = $refs
        inherited = $Inherited
        inherited_from = $InheritedFrom
        verified_at = $VerifiedAt
    }
}

function Test-ArthurGateEvidenceMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Gate,
        [object]$CurrentSubject = $null,
        [string]$CurrentRequirementDigest = ''
    )

    $status = [string](Get-ArthurStateMember $Gate 'status')
    if ($status -ne 'PASS') { return $false }

    $gateDigest = [string](Get-ArthurStateMember $Gate 'requirement_digest')
    if (-not [string]::IsNullOrWhiteSpace($CurrentRequirementDigest)) {
        $currentDigest = $CurrentRequirementDigest.Trim().ToLowerInvariant()
        if ($currentDigest -notmatch '^[0-9a-f]{64}$') { return $false }
        if ($gateDigest -ne $currentDigest) { return $false }
    }

    $subject = Get-ArthurStateMember $Gate 'subject'

    # A positive GitHub Actions run id is an immutable source identity: GitHub never
    # changes the head SHA of an existing run. Control-plane/state-only commits may
    # advance repository HEAD after that run was created; those commits must not
    # stale BUILD/ARTIFACT evidence for the same run. Candidate/artifact hashes and
    # every other subject field are still compared normally.
    $expectedRunId = 0L
    $actualRunId = 0L
    $expectedRunValue = Get-ArthurStateMember $subject 'github_run_id'
    $actualRunValue = Get-ArthurStateMember $CurrentSubject 'github_run_id'
    $expectedRunParsed = $null -ne $expectedRunValue -and [long]::TryParse([string]$expectedRunValue,[ref]$expectedRunId)
    $actualRunParsed = $null -ne $actualRunValue -and [long]::TryParse([string]$actualRunValue,[ref]$actualRunId)
    $sameImmutableRun = $expectedRunParsed -and $actualRunParsed -and $expectedRunId -gt 0 -and $expectedRunId -eq $actualRunId

    foreach ($name in @(Get-ArthurStatePropertyNames $subject)) {
        $expected = Get-ArthurStateMember $subject $name
        $actual = Get-ArthurStateMember $CurrentSubject $name
        if ($null -eq $actual -and $null -ne $expected) { return $false }

        if ($name -eq 'source_sha' -and $sameImmutableRun) {
            continue
        }

        $expectedJson = $expected | ConvertTo-Json -Compress -Depth 20
        $actualJson = $actual | ConvertTo-Json -Compress -Depth 20
        if ($expectedJson -ne $actualJson) { return $false }
    }

    $refs = @((Get-ArthurStateMember $Gate 'evidence_refs'))
    $inherited = [bool](Get-ArthurStateMember $Gate 'inherited')
    $inheritedFrom = [string](Get-ArthurStateMember $Gate 'inherited_from')
    if ($refs.Count -eq 0 -and -not ($inherited -and -not [string]::IsNullOrWhiteSpace($inheritedFrom))) { return $false }

    return $true
}

function Resolve-ArthurGateStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Gate,
        [object]$CurrentSubject = $null,
        [string]$CurrentRequirementDigest = ''
    )

    $status = [string](Get-ArthurStateMember $Gate 'status')
    if ($script:ArthurGateStatuses -notcontains $status) { throw "ARTHUR_GATE_STATUS_INVALID=$status" }
    if ($status -ne 'PASS') { return $status }

    if (-not (Test-ArthurGateEvidenceMatch -Gate $Gate -CurrentSubject $CurrentSubject -CurrentRequirementDigest $CurrentRequirementDigest)) {
        return 'STALE'
    }
    return 'PASS'
}

function Get-ArthurConfiguredReleaseMode {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace([string]$env:ARTHUR_RELEASE_MODE)) {
        return ([string]$env:ARTHUR_RELEASE_MODE).Trim()
    }

    $root = Split-Path -Parent $PSScriptRoot
    $policyPath = Join-Path $root 'production/release-mode.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw 'ARTHUR_RELEASE_MODE_POLICY_MISSING'
    }
    try {
        $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "ARTHUR_RELEASE_MODE_POLICY_INVALID=$($_.Exception.Message)"
    }
    $mode = [string](Get-ArthurStateMember $policy 'mode')
    if ([string]::IsNullOrWhiteSpace($mode)) { throw 'ARTHUR_RELEASE_MODE_MISSING' }
    return $mode.Trim()
}

function Get-ArthurEffectivePhaseOrder {
    [CmdletBinding()]
    param(
        [string]$ReleaseMode = '',
        [string[]]$PhaseOrder = @()
    )

    $mode = $ReleaseMode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = Get-ArthurConfiguredReleaseMode }
    $mode = $mode.Trim()

    if ($PhaseOrder.Count -eq 0) {
        $resumeOrder = Get-Variable -Name ArthurResumePhaseOrder -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $resumeOrder) { throw 'ARTHUR_RELEASE_PHASE_ORDER_MISSING' }
        $PhaseOrder = @($resumeOrder.Value)
    }

    if ($mode -eq 'FLASH_AND_VERIFY') { return @($PhaseOrder) }
    if ($mode -ne 'RELEASE_ONLY') { throw "ARTHUR_RELEASE_MODE_INVALID=$mode" }

    $skip = @(
        'PRE_FLASH','AUTO_FLASH_SAFETY_GATE','FLASH','WAIT_DEVICE','IDENTIFY',
        'LAN_RUNTIME','DHCP','WAN','DNS','SSH','LUCI','PLUGIN_RUNTIME_22',
        'ARGON_KUCAT_RUNTIME','SYSTEM_HEALTH'
    )
    return @($PhaseOrder | Where-Object { $skip -notcontains [string]$_ })
}

function Get-ArthurNextRequiredGate {
    [CmdletBinding()]
    param(
        [object[]]$Gates = @(),
        [string[]]$GateOrder = @(),
        [string]$ReleaseMode = ''
    )

    $effectiveOrder = @($GateOrder)
    if ($effectiveOrder -contains 'PRODUCTION_RELEASED') {
        $effectiveOrder = @(Get-ArthurEffectivePhaseOrder -ReleaseMode $ReleaseMode -PhaseOrder $effectiveOrder)
    }

    foreach ($gateId in $effectiveOrder) {
        $gate = @($Gates | Where-Object { [string](Get-ArthurStateMember $_ 'gate_id') -eq [string]$gateId } | Select-Object -First 1)
        if ($gate.Count -eq 0) { continue }
        $candidate = $gate[0]
        $status = [string](Get-ArthurStateMember $candidate 'status')
        if ($status -notin @('PASS','SKIPPED')) { return $candidate }
    }
    return $null
}
