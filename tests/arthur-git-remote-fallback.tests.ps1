$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Helper = Join-Path $Root 'scripts\arthur-git-remote.ps1'
$Repair = Join-Path $Root 'scripts\arthur-windows-repair-controller.ps1'
$Agents = Join-Path $Root 'AGENTS.md'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "TEST_FAIL: $Message expected='$Expected' actual='$Actual'" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message (missing '$Needle')" }
}

Assert-True (Test-Path -LiteralPath $Helper -PathType Leaf) 'resilient Git remote helper must exist'
. $Helper

Assert-True (Test-ArthurSchannelCredentialFailure 'schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS') 'exact Windows Schannel credential-handle failure must be recognized'
Assert-True (Test-ArthurSchannelCredentialFailure 'fatal: unable to access: schannel: failed to acquire credentials: SEC_E_NO_CREDENTIALS') 'Schannel credential wording variant must be recognized'
Assert-True (-not (Test-ArthurSchannelCredentialFailure 'HTTP 401: Bad credentials')) 'real GitHub authentication failure must not be mislabeled as Schannel transport failure'
Assert-True (-not (Test-ArthurSchannelCredentialFailure 'repository not found')) 'repository authorization/not-found errors must not be auto-bypassed'

$primary = [pscustomobject]@{ ExitCode=128; Output='schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS' }
$openssl = [pscustomobject]@{ ExitCode=128; Output='openssl retry unavailable' }
$apiOk = [pscustomobject]@{ ExitCode=0; Output='5f41c4e25be6eb5a24f78bc794ca1d80a036087c' }
$decision = Resolve-ArthurRemoteMainProbe -Primary $primary -OpenSsl $openssl -Api $apiOk
Assert-Equal $decision.status 'PASS' 'GitHub API fallback must validate remote main after Schannel-only failure'
Assert-Equal $decision.method 'GH_API' 'successful API fallback must record its method'
Assert-Equal $decision.degraded $true 'fallback success must remain auditable as degraded transport'
Assert-Equal $decision.remote_sha '5f41c4e25be6eb5a24f78bc794ca1d80a036087c' 'fallback must return exact remote SHA'
Assert-Equal $decision.human_gate $null 'Schannel-only fallback success must never create a human gate'

$opensslOk = [pscustomobject]@{ ExitCode=0; Output='5f41c4e25be6eb5a24f78bc794ca1d80a036087c`trefs/heads/main' }
$decisionOpenSsl = Resolve-ArthurRemoteMainProbe -Primary $primary -OpenSsl $opensslOk -Api $null
Assert-Equal $decisionOpenSsl.status 'PASS' 'OpenSSL Git fallback must be accepted before API fallback'
Assert-Equal $decisionOpenSsl.method 'GIT_OPENSSL' 'OpenSSL fallback method must be explicit'
Assert-Equal $decisionOpenSsl.human_gate $null 'OpenSSL fallback must not create a human gate'

$authFailure = [pscustomobject]@{ ExitCode=128; Output='remote: HTTP 401 Bad credentials' }
$authDecision = Resolve-ArthurRemoteMainProbe -Primary $authFailure -OpenSsl $null -Api $null
Assert-Equal $authDecision.status 'FAIL' 'real authentication failures must fail closed'
Assert-Equal $authDecision.method 'GIT' 'non-Schannel errors must not silently switch transport'

$allFailed = Resolve-ArthurRemoteMainProbe -Primary $primary -OpenSsl $openssl -Api ([pscustomobject]@{ ExitCode=1; Output='network unavailable' })
Assert-Equal $allFailed.status 'RETRYING' 'Schannel plus unavailable fallbacks is retryable transport failure, not human credential provisioning'
Assert-Equal $allFailed.human_gate $null 'retryable Schannel transport failure must not become NEW_CREDENTIAL_PROVISIONING'

$helperSource = Get-Content -Raw -LiteralPath $Helper
Assert-Contains $helperSource 'http.sslBackend=openssl' 'helper must retry Git with OpenSSL backend'
Assert-Contains $helperSource "@('api'" 'helper must support GitHub API fallback'
Assert-Contains $helperSource 'SEC_E_NO_CREDENTIALS' 'helper must classify the observed Schannel error explicitly'

$repairSource = Get-Content -Raw -LiteralPath $Repair
Assert-Contains $repairSource 'arthur-git-remote.ps1' 'Windows repair controller must load resilient Git transport helper'
Assert-Contains $repairSource 'Invoke-ArthurGitFetchResilient' 'control-runtime fetch must use resilient Git transport path'

$agentsSource = Get-Content -Raw -LiteralPath $Agents
Assert-Contains $agentsSource 'SEC_E_NO_CREDENTIALS' 'agent policy must forbid treating known Schannel transport failure as terminal remote-main failure'
Assert-Contains $agentsSource 'arthur-git-remote.ps1' 'agent policy must name the canonical resilient remote helper'

Write-Host 'Arthur Git remote fallback tests passed.'
