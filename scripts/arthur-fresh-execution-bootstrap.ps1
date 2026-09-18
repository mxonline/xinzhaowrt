Set-StrictMode -Version Latest

$stateContractPath = Join-Path $PSScriptRoot 'arthur-state-contract.ps1'
$evidenceHelperPath = Join-Path $PSScriptRoot 'arthur-evidence-index.ps1'
$eventLedgerHelperPath = Join-Path $PSScriptRoot 'arthur-firmware-event-ledger.ps1'
if (-not (Test-Path -LiteralPath $stateContractPath -PathType Leaf)) { throw 'FRESH_BOOTSTRAP_STATE_CONTRACT_MISSING' }
if (-not (Test-Path -LiteralPath $evidenceHelperPath -PathType Leaf)) { throw 'FRESH_BOOTSTRAP_EVIDENCE_HELPER_MISSING' }
if (-not (Test-Path -LiteralPath $eventLedgerHelperPath -PathType Leaf)) { throw 'FRESH_BOOTSTRAP_EVENT_LEDGER_HELPER_MISSING' }
. $stateContractPath
. $evidenceHelperPath
. $eventLedgerHelperPath

function Read-ArthurBootstrapJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$MissingCode)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $MissingCode }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { throw "FRESH_BOOTSTRAP_INVALID_JSON=$Path $($_.Exception.Message)" }
}

function Copy-ArthurBootstrapObject {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    return (($Value | ConvertTo-Json -Depth 40) | ConvertFrom-Json)
}

function Get-ArthurBootstrapGate {
    param([object]$Resume,[string]$GateId)
    $gates = Get-ArthurStateMember $Resume 'gates'
    if ($null -eq $gates) { return $null }
    return (Get-ArthurStateMember $gates $GateId)
}

function Get-ArthurBootstrapPolicySection {
    param([Parameter(Mandatory=$true)][string]$PolicyText,[Parameter(Mandatory=$true)][string]$Heading)
    $escaped = [regex]::Escape($Heading)
    $match = [regex]::Match($PolicyText,"(?ms)^##\s+$escaped\s*\r?\n(?<body>.*?)(?=^##\s+|\z)")
    if (-not $match.Success) { throw "FRESH_BOOTSTRAP_POLICY_SECTION_MISSING=$Heading" }
    return $match.Value.Trim()
}

function New-ArthurBootstrapPolicyGate {
    param(
        [Parameter(Mandatory=$true)][string]$GateId,
        [Parameter(Mandatory=$true)][string]$Heading,
        [Parameter(Mandatory=$true)][string]$Anchor,
        [Parameter(Mandatory=$true)][string]$PolicyText,
        [ValidateSet('PENDING','SKIPPED')][string]$Status = 'PENDING'
    )
    $section = Get-ArthurBootstrapPolicySection -PolicyText $PolicyText -Heading $Heading
    return (New-ArthurGateRecord `
        -GateId $GateId `
        -RequirementRef "production/release-policy.md#$Anchor" `
        -RequirementDigest (Get-ArthurRequirementDigest -RequirementText $section) `
        -Status $Status `
        -Subject ([pscustomobject]@{}) `
        -EvidenceRefs @())
}

function New-ArthurBootstrapInheritedGate {
    param(
        [Parameter(Mandatory=$true)][object]$PreviousResume,
        [Parameter(Mandatory=$true)][string]$GateId,
        [Parameter(Mandatory=$true)][string]$PreviousExecutionId,
        [Parameter(Mandatory=$true)][string[]]$EvidenceRefs
    )
    $old = Get-ArthurBootstrapGate -Resume $PreviousResume -GateId $GateId
    if ($null -eq $old -or [string](Get-ArthurStateMember $old 'status') -ne 'PASS') {
        throw "FRESH_BOOTSTRAP_FROZEN_GATE_NOT_PASS=$GateId"
    }
    if (@($EvidenceRefs).Count -eq 0) {
        throw "FRESH_BOOTSTRAP_FROZEN_GATE_EVIDENCE_MISSING=$GateId"
    }
    return (New-ArthurGateRecord `
        -GateId $GateId `
        -RequirementRef ([string](Get-ArthurStateMember $old 'requirement_ref')) `
        -RequirementDigest ([string](Get-ArthurStateMember $old 'requirement_digest')) `
        -Status 'PASS' `
        -Subject (Copy-ArthurBootstrapObject (Get-ArthurStateMember $old 'subject')) `
        -EvidenceRefs $EvidenceRefs `
        -Inherited $true `
        -InheritedFrom $PreviousExecutionId `
        -VerifiedAt ([string](Get-ArthurStateMember $old 'verified_at')))
}

function Get-ArthurBootstrapSemanticHash {
    param([Parameter(Mandatory=$true)][object]$State)
    $copy = Copy-ArthurBootstrapObject $State
    if ($copy.PSObject.Properties['semantic_sha256']) { $copy.PSObject.Properties.Remove('semantic_sha256') }
    return (Get-ArthurStateSha256 -Text ($copy | ConvertTo-Json -Depth 40 -Compress))
}

function Invoke-ArthurFreshExecutionBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$RepositoryHead,
        [Parameter(Mandatory=$true)][string]$RemoteMainHead,
        [Parameter(Mandatory=$true)][bool]$SourceAncestorConfirmed,
        [switch]$Apply
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $intentPath = Join-Path $rootPath 'production\operator-intent.json'
    $policyPath = Join-Path $rootPath 'production\release-mode.json'
    $resumePath = Join-Path $rootPath 'production\resume-state.json'
    $versionPath = Join-Path $rootPath 'VERSION'
    $releasePolicyPath = Join-Path $rootPath 'production\release-policy.md'
    $runtimeContractPath = Join-Path $rootPath 'runtime-contract.json'

    $intent = Read-ArthurBootstrapJson -Path $intentPath -MissingCode 'FRESH_BOOTSTRAP_OPERATOR_INTENT_MISSING'
    $policy = Read-ArthurBootstrapJson -Path $policyPath -MissingCode 'FRESH_BOOTSTRAP_RELEASE_MODE_MISSING'
    $previous = Read-ArthurBootstrapJson -Path $resumePath -MissingCode 'FRESH_BOOTSTRAP_RESUME_STATE_MISSING'

    $authorized = (
        [string]$intent.project -eq 'Arthur' -and
        [string]$intent.intent_type -eq 'EXECUTE_FIRMWARE' -and
        [string]$intent.authorization_scope -eq 'FIRMWARE_RELEASE' -and
        $intent.firmware_execution_authorized -eq $true
    )
    if (-not $authorized) {
        return [pscustomobject][ordered]@{ action='NOOP_NOT_AUTHORIZED'; execution_id=[string]$intent.execution_id }
    }

    $executionId = ([string]$intent.execution_id).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($executionId)) { throw 'FRESH_BOOTSTRAP_EXECUTION_ID_MISSING' }
    # Reuse the repository's canonical evidence-path validator for execution identity.
    [void](Get-ArthurEvidenceIndexPath -Root $rootPath -ExecutionId $executionId)

    $releaseTag = ([string]$intent.target_release).Trim()
    if ($releaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw "FRESH_BOOTSTRAP_TARGET_RELEASE_INVALID=$releaseTag" }
    $version = if (Test-Path -LiteralPath $versionPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $versionPath).Trim() } else { '' }
    if ($version -ne $releaseTag.Substring(1)) { throw "FRESH_BOOTSTRAP_VERSION_TARGET_MISMATCH version=$version target=$releaseTag" }

    if ([string]$intent.release_mode -ne 'RELEASE_ONLY' -or [string]$policy.mode -ne 'RELEASE_ONLY') { throw 'FRESH_BOOTSTRAP_RELEASE_ONLY_REQUIRED' }
    if ($policy.unattended_release -ne $true) { throw 'FRESH_BOOTSTRAP_UNATTENDED_RELEASE_REQUIRED' }
    if ($policy.automatic_flash -ne $false) { throw 'FRESH_BOOTSTRAP_AUTOMATIC_FLASH_FORBIDDEN' }
    if ($intent.device_write_authorized -ne $false) { throw 'FRESH_BOOTSTRAP_DEVICE_WRITE_FORBIDDEN' }
    if ($null -eq $intent.guardrails -or $intent.guardrails.sysupgrade_forbidden -ne $true) { throw 'FRESH_BOOTSTRAP_SYSUPGRADE_FORBIDDEN_REQUIRED' }

    $repoHead = $RepositoryHead.Trim().ToLowerInvariant()
    $remoteHead = $RemoteMainHead.Trim().ToLowerInvariant()
    if ($repoHead -notmatch '^[0-9a-f]{40}$' -or $remoteHead -notmatch '^[0-9a-f]{40}$') { throw 'FRESH_BOOTSTRAP_REPOSITORY_HEAD_INVALID' }
    if ($repoHead -ne $remoteHead) { throw "FRESH_BOOTSTRAP_REMOTE_HEAD_MISMATCH local=$repoHead remote=$remoteHead" }

    $sourceSha = ([string]$intent.firmware_state.active_source_sha).Trim().ToLowerInvariant()
    if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw "FRESH_BOOTSTRAP_SOURCE_INVALID=$sourceSha" }
    if (-not $SourceAncestorConfirmed) { throw "FRESH_BOOTSTRAP_SOURCE_NOT_ANCESTOR=$sourceSha" }

    if ([int]$previous.schema_version -ne 2) { throw 'FRESH_BOOTSTRAP_PREVIOUS_STATE_SCHEMA_INVALID' }
    $previousExecutionId = ([string]$previous.execution_id).Trim().ToLowerInvariant()
    if ($previousExecutionId -eq $executionId) {
        return [pscustomobject][ordered]@{ action='NOOP_CURRENT_EXECUTION'; execution_id=$executionId; previous_execution_id=$previousExecutionId }
    }
    if ([string]$previous.status -ne 'PRODUCTION_RELEASED' -or $previous.instruction_allowed -ne $false) {
        throw "FRESH_BOOTSTRAP_PREVIOUS_EXECUTION_NOT_TERMINAL status=$($previous.status) instruction_allowed=$($previous.instruction_allowed)"
    }

    if (-not (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf)) { throw 'FRESH_BOOTSTRAP_RELEASE_POLICY_MISSING' }
    $releasePolicyText = Get-Content -Raw -LiteralPath $releasePolicyPath

    $frozen = @($intent.firmware_state.verified_frozen | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    $previousEvidencePath = Get-ArthurEvidenceIndexPath -Root $rootPath -ExecutionId $previousExecutionId
    $previousEvidenceIndex = Read-ArthurBootstrapJson -Path $previousEvidencePath -MissingCode 'FRESH_BOOTSTRAP_PREVIOUS_EVIDENCE_INDEX_MISSING'
    $previousEvidenceRecords = @($previousEvidenceIndex.evidence)
    $inheritedEvidence = New-Object System.Collections.Generic.List[object]
    $inheritedEvidenceIds = New-Object System.Collections.Generic.HashSet[string]
    $gateMap = [ordered]@{}
    foreach ($gateId in @('WIFI','LUCI_CHINESE','QUICKSTART')) {
        if ($frozen -contains $gateId) {
            $gateEvidence = @($previousEvidenceRecords | Where-Object {
                $null -ne $_ -and
                $_.PSObject.Properties['evidence_id'] -and
                $_.PSObject.Properties['gate_id'] -and
                $_.PSObject.Properties['result'] -and
                [string]$_.gate_id -eq $gateId -and
                [string]$_.result -eq 'PASS' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.evidence_id)
            })
            if ($gateEvidence.Count -eq 0) {
                throw "FRESH_BOOTSTRAP_INHERITED_GATE_EVIDENCE_MISSING=$gateId"
            }

            $evidenceRefs = @()
            foreach ($record in @($gateEvidence | Sort-Object { [string]$_.evidence_id })) {
                $evidenceId = [string]$record.evidence_id
                $evidenceRefs += "evidence:$evidenceId"
                if ($inheritedEvidenceIds.Add($evidenceId)) {
                    $inheritedEvidence.Add((Copy-ArthurBootstrapObject $record))
                }
            }

            $gate = New-ArthurBootstrapInheritedGate `
                -PreviousResume $previous `
                -GateId $gateId `
                -PreviousExecutionId $previousExecutionId `
                -EvidenceRefs $evidenceRefs
            $gateMap[$gateId] = $gate
        }
    }

    # Already-merged product-repair phases are not rerun. The fresh production execution
    # starts at the first release gate and proves every release-relevant stage again.
    $gateMap['FORENSICS'] = New-ArthurGateRecord -GateId 'FORENSICS' -RequirementRef 'production/release-policy.md#frozen-principle' -RequirementDigest (Get-ArthurRequirementDigest -RequirementText 'fresh release execution begins after merged product repair') -Status 'SKIPPED'
    $gateMap['ADH_MANAGEMENT'] = New-ArthurGateRecord -GateId 'ADH_MANAGEMENT' -RequirementRef 'production/release-policy.md#frozen-principle' -RequirementDigest (Get-ArthurRequirementDigest -RequirementText 'fresh release execution begins after merged product repair') -Status 'SKIPPED'
    $gateMap['ADH_CHINESE'] = New-ArthurGateRecord -GateId 'ADH_CHINESE' -RequirementRef 'production/release-policy.md#frozen-principle' -RequirementDigest (Get-ArthurRequirementDigest -RequirementText 'fresh release execution begins after merged product repair') -Status 'SKIPPED'
    $gateMap['CHANGE_IMPACT'] = New-ArthurBootstrapPolicyGate -GateId 'CHANGE_IMPACT' -Heading 'Change Impact Gate' -Anchor 'change-impact-gate' -PolicyText $releasePolicyText
    $gateMap['BASELINE_INHERITANCE'] = New-ArthurBootstrapPolicyGate -GateId 'BASELINE_INHERITANCE' -Heading 'Baseline Inheritance Gate' -Anchor 'baseline-inheritance-gate' -PolicyText $releasePolicyText
    $gateMap['EXPECTED_DIFF'] = New-ArthurBootstrapPolicyGate -GateId 'EXPECTED_DIFF' -Heading 'Expected Diff Gate' -Anchor 'expected-diff-gate' -PolicyText $releasePolicyText
    $gateMap['BUILD'] = New-ArthurBootstrapPolicyGate -GateId 'BUILD' -Heading 'Build' -Anchor 'build' -PolicyText $releasePolicyText
    $gateMap['ARTIFACT'] = New-ArthurBootstrapPolicyGate -GateId 'ARTIFACT' -Heading 'Artifact' -Anchor 'artifact' -PolicyText $releasePolicyText
    $gateMap['RELEASE_GATE'] = New-ArthurBootstrapPolicyGate -GateId 'RELEASE_GATE' -Heading 'Release Gate' -Anchor 'release-gate' -PolicyText $releasePolicyText
    $gateMap['RELEASE'] = New-ArthurBootstrapPolicyGate -GateId 'RELEASE' -Heading 'Release' -Anchor 'release' -PolicyText $releasePolicyText
    $gateMap['PRODUCTION_RELEASED'] = New-ArthurBootstrapPolicyGate -GateId 'PRODUCTION_RELEASED' -Heading 'Production Released' -Anchor 'production-released' -PolicyText $releasePolicyText

    $oldDevice = Copy-ArthurBootstrapObject (Get-ArthurStateMember $previous 'device')
    if ($null -eq $oldDevice) { $oldDevice = [pscustomobject]@{} }
    $resume = [pscustomobject][ordered]@{
        schema_version = 2
        execution_id = $executionId
        status = 'RESUME_SAFE'
        instruction_allowed = $true
        release = $releaseTag
        source = [pscustomobject][ordered]@{
            repository_head = $repoHead
            accepted_source_sha = $sourceSha
            accepted_release = $releaseTag
            accepted_firmware = ''
            accepted_firmware_sha256 = ''
            accepted_factory_sha256 = ''
        }
        production = [pscustomobject][ordered]@{
            github_run_id = [long]0
            artifact_id = [long]0
            release_id = [long]0
            release = $releaseTag
            release_url = ''
            firmware = ''
            candidate_sha256 = ''
            factory_sha256 = ''
        }
        device = $oldDevice
        gates = [pscustomobject]$gateMap
        current_gate = 'CHANGE_IMPACT'
        next_action = 'CHANGE_IMPACT'
        repository_head = $repoHead
        real_device = $oldDevice
        checkpoint = [pscustomobject][ordered]@{
            current = 'CHANGE_IMPACT'
            next_action = 'CHANGE_IMPACT'
            turn_count = 0
        }
        verified = [pscustomobject][ordered]@{
            real_device_baseline = 'ROLLBACK_AUTHORITY_PRESERVED'
            wifi = $(if ($frozen -contains 'WIFI') { 'VERIFIED_FROZEN' } else { 'REVERIFY_REQUIRED' })
            luci_chinese = $(if ($frozen -contains 'LUCI_CHINESE') { 'VERIFIED_FROZEN' } else { 'REVERIFY_REQUIRED' })
            adguard_full_manager = 'REVERIFY_REQUIRED'
            quickstart = $(if ($frozen -contains 'QUICKSTART') { 'VERIFIED_FROZEN' } else { 'REVERIFY_REQUIRED' })
        }
        pending = @('CHANGE_IMPACT')
        conflicts = @()
        post_release_device_test = 'PENDING_INDEPENDENT'
        source_precedence = @('GITHUB_AUTHORIZED_EXECUTION','GITHUB_HEAD','KNOWN_GOOD_ROLLBACK_AUTHORITY','HISTORICAL_DOCS_AUXILIARY_ONLY')
        legacy_source_policy = 'AUXILIARY_ONLY'
        ignored_current_state_sources = @('local user worktree','host push bridge','chat/model narrative')
    }
    $resume | Add-Member -NotePropertyName semantic_sha256 -NotePropertyValue (Get-ArthurBootstrapSemanticHash -State $resume)

    $evidenceIndex = [pscustomobject][ordered]@{
        schema_version = 1
        execution_id = $executionId
        evidence = @($inheritedEvidence)
    }
    $event = [pscustomobject][ordered]@{
        event = 'EXECUTION_STARTED'
        stage = 'CHANGE_IMPACT'
        source = 'GITHUB_NATIVE_FRESH_EXECUTION_BOOTSTRAP'
        data = [pscustomobject][ordered]@{
            execution_id = $executionId
            previous_execution_id = $previousExecutionId
            target_release = $releaseTag
            release_mode = 'RELEASE_ONLY'
            accepted_source_sha = $sourceSha
            repository_head = $repoHead
            device_write_authorized = $false
            automatic_flash = $false
        }
    }

    $result = [pscustomobject][ordered]@{
        action = 'BOOTSTRAP_REQUIRED'
        execution_id = $executionId
        previous_execution_id = $previousExecutionId
        target_release = $releaseTag
        repository_head = $repoHead
        accepted_source_sha = $sourceSha
        resume_state = $resume
        evidence_index = $evidenceIndex
        event = $event
    }

    if ($Apply) {
        $eventLedgerPath = Join-Path $rootPath 'production\firmware-events.jsonl'
        if (-not (Test-Path -LiteralPath $eventLedgerPath -PathType Leaf)) {
            throw 'FRESH_BOOTSTRAP_EVENT_LEDGER_MISSING'
        }
        [void](Test-ArthurFirmwareEventLedger -Path $eventLedgerPath)

        $evidenceIndexPath = Get-ArthurEvidenceIndexPath -Root $rootPath -ExecutionId $executionId
        Write-ArthurEvidenceIndex -Path $evidenceIndexPath -Index $evidenceIndex

        $existingEvents = @(Get-ArthurFirmwareEvents -Path $eventLedgerPath)
        $alreadyStarted = @($existingEvents | Where-Object {
            [string]$_.event -eq 'EXECUTION_STARTED' -and
            $_.PSObject.Properties['data'] -and
            [string]$_.data.execution_id -eq $executionId
        }).Count -gt 0
        if (-not $alreadyStarted) {
            $null = Add-ArthurFirmwareEvent -Path $eventLedgerPath -Event $event.event -Stage $event.stage -Source $event.source -Data $event.data
        }

        $tmp = "$resumePath.$PID.tmp"
        [IO.File]::WriteAllText($tmp,($resume | ConvertTo-Json -Depth 40) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $resumePath -Force

        $runtimeContract = Read-ArthurBootstrapJson -Path $runtimeContractPath -MissingCode 'FRESH_BOOTSTRAP_RUNTIME_CONTRACT_MISSING'
        if ($null -eq $runtimeContract.bundles -or @($runtimeContract.bundles).Count -ne 1) { throw 'FRESH_BOOTSTRAP_RUNTIME_CONTRACT_BUNDLE_INVALID' }
        $runtimeContract.bundles[0].execution_id = $executionId
        $runtimeContract.bundles[0].state = 'production/resume-state.json'
        $runtimeContract.bundles[0].events = 'production/firmware-events.jsonl'
        $runtimeContract.bundles[0].evidence = "production/evidence/$executionId/index.json"
        $contractTmp = "$runtimeContractPath.$PID.tmp"
        [IO.File]::WriteAllText($contractTmp,($runtimeContract | ConvertTo-Json -Depth 20) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $contractTmp -Destination $runtimeContractPath -Force

        $result.action = 'BOOTSTRAPPED'
    }
    return $result
}
