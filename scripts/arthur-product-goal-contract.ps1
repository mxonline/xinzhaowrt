Set-StrictMode -Version Latest

function Get-ArthurProductGoalContract {
    param([string]$Root = '')

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    $path = Join-Path $Root 'production\product-goal-contract.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'PRODUCT_GOAL_CONTRACT_MISSING'
    }
    try {
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 20)
    }
    catch {
        throw "PRODUCT_GOAL_CONTRACT_INVALID_JSON: $($_.Exception.Message)"
    }
}

function Assert-ArthurProductGoalContract {
    param([string]$Root = '')

    $contract = Get-ArthurProductGoalContract -Root $Root

    if ([string]$contract.schema_version -ne '1.0') { throw 'PRODUCT_GOAL_CONTRACT_SCHEMA_UNSUPPORTED' }
    if ([string]$contract.authority -ne 'OPERATOR') { throw 'PRODUCT_GOAL_CONTRACT_AUTHORITY_INVALID' }
    if ([string]$contract.priority_class -ne 'HIGHEST') { throw 'PRODUCT_GOAL_CONTRACT_PRIORITY_INVALID' }
    if ([string]$contract.contract_id -ne 'ARTHUR_PRODUCT_GOAL_V1') { throw 'PRODUCT_GOAL_CONTRACT_ID_INVALID' }
    if ([string]$contract.scope -ne 'ALL_ARTHUR_LIFECYCLE_STAGES_AND_ALL_AUTOMATION') { throw 'PRODUCT_GOAL_CONTRACT_SCOPE_INVALID' }

    if ([string]$contract.goal.product_terminal -ne 'PRODUCT_GOAL_VERIFIED') { throw 'PRODUCT_GOAL_TERMINAL_INVALID' }
    if ([string]$contract.goal.release_pipeline_terminal -ne 'PRODUCTION_RELEASED') { throw 'PRODUCT_GOAL_RELEASE_TERMINAL_INVALID' }

    $requiredCapabilities = @(
        'LAN','DHCP','WAN','DNS','SSH','LUCI','WIFI','ISTORE_QUICKSTART',
        'OPENCLASH_FULLY_USABLE','ADGUARDHOME_FULLY_USABLE',
        'OPENCLASH_ADH_COEXISTENCE','REBOOT_PERSISTENCE','SYSTEM_HEALTH'
    )
    $actualCapabilities = @($contract.required_real_device_capabilities)
    foreach ($capability in $requiredCapabilities) {
        if ($actualCapabilities -notcontains $capability) {
            throw "PRODUCT_GOAL_REQUIRED_CAPABILITY_MISSING=$capability"
        }
    }

    if ($contract.openclash_adguardhome_coexistence.required -ne $true) { throw 'PRODUCT_GOAL_COEXISTENCE_NOT_REQUIRED' }
    if ($contract.openclash_adguardhome_coexistence.process_presence_is_insufficient -ne $true) { throw 'PRODUCT_GOAL_PID_ONLY_MUST_BE_INSUFFICIENT' }
    if ([string]$contract.openclash_adguardhome_coexistence.required_dns_chain -ne 'LAN:dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874') {
        throw 'PRODUCT_GOAL_DNS_CHAIN_INVALID'
    }

    foreach ($marker in @(
        'OPENCLASH_FULLY_USABLE=PASS',
        'ADGUARDHOME_FULLY_USABLE=PASS',
        'OPENCLASH_ADH_COEXISTENCE=PASS'
    )) {
        if (@($contract.openclash_adguardhome_coexistence.required_markers) -notcontains $marker) {
            throw "PRODUCT_GOAL_COEXISTENCE_MARKER_MISSING=$marker"
        }
    }

    foreach ($flag in @(
        'every_stage_must_load_this_contract',
        'stage_success_must_not_override_product_goal',
        'build_success_is_not_product_success',
        'release_success_is_not_product_success',
        'static_verification_is_not_product_success',
        'simultaneous_process_presence_is_not_coexistence_success',
        'live_validate_before_build_when_safe_and_applicable',
        'do_not_build_known_broken_behavior',
        'do_not_promote_known_good_until_exact_release_real_device_acceptance_passes'
    )) {
        if ($contract.execution_rules.$flag -ne $true) {
            throw "PRODUCT_GOAL_EXECUTION_RULE_DISABLED=$flag"
        }
    }

    foreach ($flag in @(
        'unattended_where_safely_possible',
        'fast',
        'safe',
        'reproducible',
        'no_routine_manual_confirmation',
        'fail_closed_on_real_safety_ambiguity'
    )) {
        if ($contract.workflow_quality.$flag -ne $true) {
            throw "PRODUCT_GOAL_WORKFLOW_QUALITY_DISABLED=$flag"
        }
    }

    if ($contract.evidence_rules.machine_evidence_required -ne $true) { throw 'PRODUCT_GOAL_MACHINE_EVIDENCE_NOT_REQUIRED' }
    if ($contract.evidence_rules.product_goal_verified_requires_exact_release_identity -ne $true) { throw 'PRODUCT_GOAL_EXACT_RELEASE_EVIDENCE_NOT_REQUIRED' }

    foreach ($marker in @(
        'OPENCLASH_FULLY_USABLE=PASS',
        'ADGUARDHOME_FULLY_USABLE=PASS',
        'OPENCLASH_ADH_COEXISTENCE=PASS',
        'POST_RELEASE_VALIDATED',
        'PRODUCT_GOAL_VERIFIED'
    )) {
        if (@($contract.evidence_rules.required_final_markers) -notcontains $marker) {
            throw "PRODUCT_GOAL_FINAL_MARKER_MISSING=$marker"
        }
    }

    Write-Host "ARTHUR_PRODUCT_GOAL_CONTRACT=PASS id=$($contract.contract_id) priority=$($contract.priority_class) product_terminal=$($contract.goal.product_terminal)"
    return $contract
}
