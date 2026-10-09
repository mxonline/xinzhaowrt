param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$originalLocation = Get-Location
$originalPath = $null
$originalPythonBin = $null
Push-Location $projectRoot
try {
    $plugins = @(Get-Content 'config/required-plugins.txt' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
    if ($plugins.Count -ne 22) { throw "ERROR: expected 22 mandatory LuCI plugins, found $($plugins.Count)" }
    if ($plugins -contains 'luci-app-istore') { throw 'ERROR: luci-app-istore does not exist; use luci-app-store.' }
    $duplicates = @($plugins | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count -gt 0) { throw "ERROR: duplicate plugins: $($duplicates -join ', ')" }

    $config = Get-Content 'config/arthur.config'
    foreach ($plugin in $plugins) {
        if ($config -notcontains "CONFIG_PACKAGE_${plugin}=y") {
            throw "ERROR: config/arthur.config does not enable $plugin"
        }
    }

    $gitCommand = Get-Command git -ErrorAction Stop
    $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
    $bash = Join-Path $gitRoot 'usr\bin\bash.exe'
    $sh = Join-Path $gitRoot 'usr\bin\sh.exe'
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw "ERROR: Bash not found at $bash" }
    if (-not (Test-Path -LiteralPath $sh -PathType Leaf)) { throw "ERROR: POSIX sh not found at $sh" }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) { throw 'ERROR: Python 3.10 or newer is required.' }
    $python = $pythonCommand.Source
    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $pythonVersion -notmatch '^Python\s+(\d+)\.(\d+)') {
        throw 'ERROR: Python version could not be determined.'
    }
    $pythonMajor = [int]$Matches[1]
    $pythonMinor = [int]$Matches[2]
    if ($pythonMajor -lt 3 -or ($pythonMajor -eq 3 -and $pythonMinor -lt 10)) {
        throw "ERROR: Python 3.10 or newer is required; found $pythonVersion at $python"
    }
    $originalPath = $env:PATH
    $originalPythonBin = $env:PYTHON_BIN
    $env:PATH = (@((Join-Path $gitRoot 'usr\bin'),(Join-Path $gitRoot 'bin'),(Split-Path -Parent $python),$originalPath) | Where-Object { $_ }) -join ';'
    $env:PYTHON_BIN = $python

    function Invoke-ProjectCheck {
        param([Parameter(Mandatory=$true)][string]$Label,[Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string[]]$Arguments)
        Write-Host "RUN=$Label"
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& $Executable @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $oldPreference }
        foreach ($line in $output) { Write-Host ([string]$line) }
        if ($exitCode -ne 0) { throw "ERROR: $Label failed with exit code $exitCode" }
    }

    Invoke-ProjectCheck 'scripts/check-defaults.sh' $bash @('scripts/check-defaults.sh')
    Invoke-ProjectCheck 'scripts/check-upload-oom-fix.sh' $bash @('scripts/check-upload-oom-fix.sh')

    $testScripts = @(
        'tests/test-version-identity-gate.sh',
        'tests/test-expected-diff-gate.sh',
        'tests/test-adguard-source-of-truth.sh',
        'tests/test-live-preview-contract.sh',
        'tests/test-package-source-provenance.sh',
        'tests/test-linkease-safe-payload.sh',
        'tests/test-linkease-source-binding.sh',
        'tests/test-full-openclash-adh-contract.sh',
        'tests/test-prebuild-openclash-adh-live-gate.sh',
        'tests/test-arthur-v016-source-identity.sh',
        'tests/test-package-manager-concurrency-gate.sh'
    )
    foreach ($test in $testScripts) { Invoke-ProjectCheck $test $bash @($test) }

    # This test invokes another Bash process. Run that child independently, then
    # run the parent checks from a same-directory temporary copy with only the
    # already-covered child invocation replaced, avoiding Git Bash's nested
    # process signal-pipe failure on Windows.
    $functionalPath = Join-Path $projectRoot 'tests/test-functional-acceptance.sh'
    $functionalText = [System.IO.File]::ReadAllText($functionalPath)
    $nestedCall = 'PYTHON_BIN="$python_bin" bash "$root/tests/test-adguard-source-of-truth.sh"'
    if (($functionalText.Split([string[]]@($nestedCall),[StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'ERROR: functional-acceptance nested check shape changed; review PowerShell verification.'
    }
    $functionalText = $functionalText.Replace($nestedCall,'true # child test already ran as an independent process')
    $temporaryFunctional = Join-Path $projectRoot ("tests/.verify-project-functional-{0}.sh" -f $PID)
    try {
        [System.IO.File]::WriteAllText($temporaryFunctional,$functionalText,[Text.UTF8Encoding]::new($false))
        Invoke-ProjectCheck 'tests/test-functional-acceptance.sh' $bash @((Resolve-Path $temporaryFunctional).Path)
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporaryFunctional }

    Invoke-ProjectCheck 'tests/test-openclash-adguardhome-coexistence.py' $python @('tests/test-openclash-adguardhome-coexistence.py')
    Invoke-ProjectCheck 'tests/test-prebuild-stable-inherited-evidence.py' $python @('tests/test-prebuild-stable-inherited-evidence.py')
    Invoke-ProjectCheck 'tests/test-stable-overlay-inheritance.py' $python @('tests/test-stable-overlay-inheritance.py')
    Invoke-ProjectCheck 'tests/test-luci-smoke-hostpkg-runtime.py' $python @('tests/test-luci-smoke-hostpkg-runtime.py')
    Invoke-ProjectCheck 'scripts/check-product-goal-contract.py' $python @('scripts/check-product-goal-contract.py')
    foreach ($json in @(
        'production/live-preview-policy.json',
        'production/mature-ui-sources.json',
        'production/openclash-adguardhome-coexistence.json'
    )) {
        Invoke-ProjectCheck "JSON $json" $python @('-m','json.tool',$json)
    }

    foreach ($script in Get-ChildItem 'scripts' -Filter '*.sh' -File | Sort-Object Name) {
        $relative = "scripts/$($script.Name)"
        Invoke-ProjectCheck "bash -n $relative" $bash @('-n',$relative)
    }
    foreach ($script in @(
        'files/etc/uci-defaults/99-xinzhao-defaults',
        'files/etc/uci-defaults/98-xinzhao-dns-coexist',
        'files/etc/init.d/xinzhao-dns-coexist',
        'files/usr/libexec/xinzhao-dns-coexist'
    )) {
        Invoke-ProjectCheck "sh -n $script" $sh @('-n',$script)
    }

    $packageCheckMode = @(git ls-files --stage -- scripts/check-package-existence.sh)
    if ($LASTEXITCODE -ne 0 -or $packageCheckMode.Count -ne 1 -or $packageCheckMode[0] -notmatch '^100755\s') {
        throw 'ERROR: scripts/check-package-existence.sh must be executable in Git.'
    }

    Write-Host 'VERIFY_PROJECT=PASS'
}
finally {
    if ($null -ne $originalPath) { $env:PATH = $originalPath }
    if ($null -eq $originalPythonBin) { Remove-Item Env:PYTHON_BIN -ErrorAction SilentlyContinue }
    else { $env:PYTHON_BIN = $originalPythonBin }
    Pop-Location
}
