$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Root 'scripts/arthur-release-only-state.ps1')

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -cne $Expected) { throw "TEST_FAIL: $Message (expected '$Expected', got '$Actual')" }
}

$status = [pscustomobject][ordered]@{
    schema_version = '3.0'
    status = 'PRODUCTION_RELEASED'
    stage = 'production'
    version = 'v0.1.5'
    known_good = $true
    device_exact_artifact_match = 'PASS'
    live_reboot_persistence = 'PASS'
    postflash_quickstart_source_status = 'PASS'
    evidence = @('https://github.com/mxonline/xinzhaowrt/releases/tag/arthur-production-36764137044')
    rollback = [pscustomobject][ordered]@{
        stable_tag = 'arthur-production-36348777394'
        sha256 = '97c7860df005e3d222d64f91872933c65ce5c77f4063ec641764f1013cf504e4'
    }
}

$updated = Complete-ArthurReleaseOnlyStatus `
    -Status $status `
    -RunId 38000704263 `
    -ArtifactId 11655711894 `
    -CandidateTag 'arthur-update-38000704263' `
    -CandidateReleaseId 408493442 `
    -CandidateReleaseUrl 'https://github.com/mxonline/xinzhaowrt/releases/tag/arthur-update-38000704263' `
    -ActionsArtifactSha256 '29b3e95051501c16076a0ec1c4d1ce4ec9d27293faccddfa7e24b2838fe690c7' `
    -ReleaseTag 'v0.1.6' `
    -SourceSha 'b4448e62ab1e767f9a60221b0600c60c355baf56' `
    -Firmware 'XinZhaoWrt-Arthur-v0.1.6-20261009-sysupgrade.bin' `
    -FirmwareSha256 'e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39' `
    -FactoryFirmware 'XinZhaoWrt-Arthur-v0.1.6-20261009-factory.bin' `
    -FactorySha256 'ea15c18b3e1b28ab454a25b540ab6e7389e5f9504494cc8ebd8c06a056fff44f' `
    -ReleaseId 408579983 `
    -ReleaseUrl 'https://github.com/mxonline/xinzhaowrt/releases/tag/v0.1.6' `
    -VerifiedAt '2026-10-10T11:11:51.8866566+08:00'

Assert-Equal $updated.status 'PRODUCTION_RELEASED' 'Release-only status must record the new stable release'
Assert-Equal $updated.version 'v0.1.6' 'Status must identify the released version'
Assert-Equal $updated.build_run_id '38000704263' 'Status must bind the exact build run'
Assert-Equal $updated.artifact_id '11655711894' 'Status must bind the exact Actions artifact'
Assert-Equal $updated.actions_artifact_sha256 '29b3e95051501c16076a0ec1c4d1ce4ec9d27293faccddfa7e24b2838fe690c7' 'Status must bind the exact Actions artifact archive digest'
Assert-Equal $updated.source_commit 'b4448e62ab1e767f9a60221b0600c60c355baf56' 'Status must bind the frozen firmware source'
Assert-Equal $updated.sysupgrade_sha256 'e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39' 'Status must bind the released sysupgrade bytes'
Assert-Equal $updated.factory_sha256 'ea15c18b3e1b28ab454a25b540ab6e7389e5f9504494cc8ebd8c06a056fff44f' 'Status must bind the released factory bytes'
Assert-Equal $updated.known_good $false 'Release-only status must not promote untested firmware to Known-Good'
Assert-Equal $updated.product_goal_status 'POST_RELEASE_VALIDATION_PENDING' 'Product verification must remain pending for the exact release'
Assert-Equal $updated.NEXT_ACTION 'POST_RELEASE_DEVICE_VALIDATION' 'Release status must identify the independent exact-artifact device validation as the next action'
Assert-Equal $updated.updated_at '2026-10-10T11:11:51.8866566+08:00' 'Status update time must preserve the evidence timestamp in stable ISO form'
Assert-Equal $updated.device_exact_artifact_match 'PENDING_INDEPENDENT' 'Prior-version device verification must not carry over to the new release'
Assert-Equal $updated.live_reboot_persistence 'PENDING_INDEPENDENT' 'Prior-version persistence evidence must not carry over to the new release'
Assert-Equal $updated.postflash_quickstart_source_status 'PENDING_INDEPENDENT' 'Prior-version postflash evidence must not carry over to the new release'
Assert-Equal $updated.rollback.stable_tag 'arthur-production-36348777394' 'Release status must preserve the authorized rollback identity'
Assert-Equal $updated.rollback.sha256 '97c7860df005e3d222d64f91872933c65ce5c77f4063ec641764f1013cf504e4' 'Release status must preserve the authorized rollback bytes'
if ($updated.evidence -notcontains 'https://github.com/mxonline/xinzhaowrt/releases/tag/arthur-production-36764137044') { throw 'TEST_FAIL: release status must preserve prior formal evidence references' }
if ($updated.evidence -notcontains 'https://github.com/mxonline/xinzhaowrt/releases/tag/arthur-update-38000704263') { throw 'TEST_FAIL: release status must add the exact Candidate reference' }
if ($updated.evidence -notcontains 'https://github.com/mxonline/xinzhaowrt/releases/tag/v0.1.6') { throw 'TEST_FAIL: release status must add the current Stable reference' }

Write-Host 'ARTHUR_RELEASE_ONLY_STATUS_TRANSITION=PASS'
