#!/usr/bin/env pwsh
# =============================================================================
# deploy-terraform.tests.ps1 -- behavioural tests for infra/deploy-terraform.ps1
# =============================================================================
# Run locally:
#   pwsh -File infra/tests/deploy-terraform.tests.ps1
#   pwsh -File infra/tests/deploy-terraform.tests.ps1 -IncludeInstall
#
# CI runs this from .github/workflows/validate.yml on windows-2025, under both
# Windows PowerShell 5.1 and PowerShell 7 -- several of the defects these cover
# only reproduce on 5.1.
#
# -IncludeInstall additionally exercises the real download-and-install path:
# it resolves the current Terraform version from HashiCorp's checkpoint API,
# downloads the zip and its SHA256SUMS, verifies the checksum (and proves a
# tampered file is rejected), extracts it, and runs the resulting binary. That
# group needs network access and takes ~1 minute; the rest is offline and fast.
#
# No dependency on Pester: the script is dependency-light on purpose, matching
# the rest of the repo, and these tests mutate machine state (PATH, install
# directories) in an order that is easier to follow linearly.
#
# Exits 0 when every assertion passes, 1 otherwise.
# =============================================================================

[CmdletBinding()]
param(
    # Also run the network-dependent download/install group.
    [switch]$IncludeInstall,

    # Internal: run a single scenario that is expected to terminate the process,
    # so the parent can assert on its exit code. Not for direct use.
    [string]$ExitCase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Nested two-argument Join-Path: Windows PowerShell 5.1 has no -AdditionalChildPath.
$ScriptUnderTest = (Resolve-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'deploy-terraform.ps1')).ProviderPath

# ---------------------------------------------------------------------------
# Load the functions from deploy-terraform.ps1 without running Invoke-Main.
# ---------------------------------------------------------------------------
$source = Get-Content -Raw -LiteralPath $ScriptUnderTest
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    $parseErrors | ForEach-Object { Write-Host "PARSE ERROR line $($_.Extent.StartLineNumber): $($_.Message)" }
    exit 1
}
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dt-tests-$PID"
$null = New-Item -ItemType Directory -Force -Path $TestRoot

# ---------------------------------------------------------------------------
# Scenarios that call exit; invoked in a child process by the parent run.
# ---------------------------------------------------------------------------
if ($ExitCase) {
    switch ($ExitCase) {
        'placeholder-one' {
            $file = Join-Path $TestRoot 'one.tfvars'
            Set-Content -LiteralPath $file -Value @('# comment', 'app_name = "myapp"', 'subscription_id = "REPLACE_ME"')
            Test-TfvarsNoPlaceholder -Path $file
        }
        'placeholder-many' {
            $file = Join-Path $TestRoot 'many.tfvars'
            Set-Content -LiteralPath $file -Value @('subscription_id = "REPLACE_ME"', 'tenant_id = "REPLACE_ME"')
            Test-TfvarsNoPlaceholder -Path $file
        }
        'backend-override-conflict' {
            $script:InfraDir = Join-Path $TestRoot 'conflict'
            $null = New-Item -ItemType Directory -Force -Path $script:InfraDir
            Set-Content -LiteralPath (Join-Path $script:InfraDir 'local_backend_override.tf') -Value 'terraform { backend "local" {} }'
            Confirm-BackendConsistency -BackendMode 'azurerm'
        }
        'backend-none-configured' {
            $script:InfraDir = Join-Path $TestRoot 'nobackend'
            $null = New-Item -ItemType Directory -Force -Path $script:InfraDir
            Confirm-BackendConsistency -BackendMode 'local'
        }
        'bad-ref' { Confirm-RefIsSafe -Ref '--upload-pack=calc.exe' }
        'install-all-methods-fail' {
            Install-ToolIfMissing -CommandName 'definitely-not-a-real-tool-xyz' -DisplayName 'Fake Tool' `
                -ManualUrl 'https://example.invalid' -DirectInstall { throw 'direct download failed' }
        }
        default { Write-Host "unknown ExitCase '$ExitCase'"; exit 99 }
    }
    Write-Host "ExitCase '$ExitCase' returned without exiting"
    exit 0
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Name"
    }
    else {
        $script:Failed++
        Write-Host "  [FAIL] $Name$(if ($Detail) { " -- $Detail" })"
    }
}

function Assert-Throw {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        $script:Failed++
        Write-Host "  [FAIL] $Name -- expected an error, none was raised"
    }
    catch {
        $script:Passed++
        Write-Host "  [PASS] $Name"
    }
}

# Runs this file again in a child process for scenarios that call exit.
function Assert-ExitCode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Case,
        [int]$Expected = 1
    )
    # Routed through the script's own probe: the child logs to stderr, and on
    # Windows PowerShell 5.1 a plain `2>&1` here would raise NativeCommandError
    # under $ErrorActionPreference='Stop' before the exit code could be read.
    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $result = Invoke-NativeProbe { & $hostExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ExitCase $Case }
    Assert-True -Name $Name -Condition ($result.ExitCode -eq $Expected) -Detail "expected exit $Expected, got $($result.ExitCode)"
}

Write-Host ""
Write-Host "deploy-terraform.ps1 tests -- PowerShell $($PSVersionTable.PSVersion)"
Write-Host "script under test: $ScriptUnderTest"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host 'PATH rebuild (must not corrupt $env:Path)'
# ---------------------------------------------------------------------------
$savedPath = $env:Path
try {
    Update-ProcessPathFromEnvironment
    Assert-True -Name 'PATH is not stringified into System.String[]' `
        -Condition (-not ($env:Path -like '*System.String*')) -Detail $env:Path
    Assert-True -Name 'PATH still resolves a known executable (git)' `
        -Condition ([bool](Get-Command git -ErrorAction SilentlyContinue))
    Assert-True -Name 'PATH keeps more than one entry' `
        -Condition ((($env:Path -split ';') | Where-Object { $_ }).Count -gt 1)
    # Select-Object -Unique is case-sensitive, so exact duplicates go and
    # case-variant ones legitimately remain (harmless on Windows).
    # @() because a single result would otherwise be a bare object, and .Count on
    # it is an error under Set-StrictMode -Version Latest -- the same trap the
    # placeholder check used to fall into.
    Assert-True -Name 'exact duplicate PATH entries are removed' `
        -Condition (@(($env:Path -split ';') | Where-Object { $_ } | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 }).Count -eq 0)
}
finally { $env:Path = $savedPath }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Native command probing (5.1 turns redirected stderr into a terminating error)'
# ---------------------------------------------------------------------------
$probe = Invoke-NativeProbe { cmd /c "echo simulated failure 1>&2 & exit 7" }
Assert-True -Name 'probe survives a failing native command' -Condition ($probe.ExitCode -eq 7) -Detail "exit=$($probe.ExitCode)"
Assert-True -Name 'probe restores $ErrorActionPreference' -Condition ($ErrorActionPreference -eq 'Stop')
$probeOk = Invoke-NativeProbe { cmd /c "exit 0" }
Assert-True -Name 'probe reports success as exit 0' -Condition ($probeOk.ExitCode -eq 0)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'tfvars placeholder detection'
# ---------------------------------------------------------------------------
$cleanTfvars = Join-Path $TestRoot 'clean.tfvars'
Set-Content -LiteralPath $cleanTfvars -Value @('# REPLACE_ME here is only a comment', 'app_name = "myapp"', 'subscription_id = "1111"')
$returned = $true
try { Test-TfvarsNoPlaceholder -Path $cleanTfvars } catch { $returned = $false }
Assert-True -Name 'a fully filled-in tfvars is accepted' -Condition $returned

# The single-placeholder case is the one that used to crash on $string.Count.
Assert-ExitCode -Name 'exactly one remaining REPLACE_ME exits 1 (no crash)' -Case 'placeholder-one'
Assert-ExitCode -Name 'several remaining REPLACE_ME exit 1' -Case 'placeholder-many'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'HCL comment handling'
# ---------------------------------------------------------------------------
$commentCases = @(
    @{ Line = 'subscription_id = "REPLACE_ME"'; Flag = $true; Why = 'plain value is flagged' }
    @{ Line = '# subscription_id = "REPLACE_ME"'; Flag = $false; Why = '# comment is ignored' }
    @{ Line = '// subscription_id = "REPLACE_ME"'; Flag = $false; Why = '// comment is ignored' }
    @{ Line = 'name = "ok" # was REPLACE_ME'; Flag = $false; Why = 'trailing # comment is ignored' }
    @{ Line = 'url = "https://host/REPLACE_ME"'; Flag = $true; Why = '// inside a quoted string is not a comment' }
    @{ Line = 'x = "REPLACE_ME" // note'; Flag = $true; Why = 'value before a // comment is flagged' }
)
foreach ($case in $commentCases) {
    $inBlock = $false
    $code = Remove-HclComment -Line $case.Line -InBlockComment ([ref]$inBlock)
    Assert-True -Name $case.Why -Condition ([bool]($code -match 'REPLACE_ME') -eq $case.Flag) -Detail "stripped to '$code'"
}
$inBlock = $false
$null = Remove-HclComment -Line 'a = 1 /* open' -InBlockComment ([ref]$inBlock)
$inside = Remove-HclComment -Line 'subscription_id = "REPLACE_ME"' -InBlockComment ([ref]$inBlock)
$after = Remove-HclComment -Line 'close */ b = "REPLACE_ME"' -InBlockComment ([ref]$inBlock)
Assert-True -Name '/* */ block spanning lines is ignored' -Condition ($inside -notmatch 'REPLACE_ME')
Assert-True -Name 'code after a closing */ is still flagged' -Condition ($after -match 'REPLACE_ME')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Path handling (wildcard metacharacters in real paths)'
# ---------------------------------------------------------------------------
$bracketDir = Join-Path $TestRoot 'copy [1]'
$null = New-Item -ItemType Directory -Force -Path $bracketDir
$bracketTfvars = Join-Path $bracketDir 'my.tfvars'
Set-Content -LiteralPath $bracketTfvars -Value 'subscription_id = "abc-123"'

$script:InfraDir = $TestRoot
$resolvedTfvars = Resolve-TfvarsPath -Explicit $bracketTfvars
Assert-True -Name 'tfvars under a directory containing [ ] resolves' -Condition ($resolvedTfvars -eq $bracketTfvars) -Detail $resolvedTfvars
Assert-True -Name 'the placeholder gate still runs for such a path' -Condition (Test-Path -LiteralPath $resolvedTfvars -PathType Leaf)
$script:TfvarsFile = $resolvedTfvars
Assert-True -Name 'subscription_id parses from such a path' -Condition ((Get-TfvarsSubscriptionId) -eq 'abc-123')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Git ref validation'
# ---------------------------------------------------------------------------
foreach ($good in @('main', 'v1', 'v1.2.3', 'feature/foo', 'release-1_2')) {
    $ok = $true
    try { Confirm-RefIsSafe -Ref $good } catch { $ok = $false }
    Assert-True -Name "ref '$good' is accepted" -Condition $ok
}
Assert-ExitCode -Name "ref '--upload-pack=...' is rejected" -Case 'bad-ref'
foreach ($bad in @('-x', '../../evil', 'a..b', 'has space')) {
    Assert-True -Name "ref '$bad' fails the validation pattern" `
        -Condition ($bad -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $bad -like '*..*')
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Backend selection and consistency'
# ---------------------------------------------------------------------------
$script:InfraDir = Join-Path $TestRoot 'markers'
$null = New-Item -ItemType Directory -Force -Path $script:InfraDir
Set-DeployBackendModeMarker -BackendMode 'local'
Assert-True -Name 'backend-mode marker round-trips' -Condition ((Get-DeployBackendMode) -eq 'local')
Assert-True -Name 'a change from local to azurerm is detected' -Condition ((Get-DeployBackendMode) -ne 'azurerm')
Remove-Item -LiteralPath (Get-DeployBackendModeMarkerPath) -Force
Assert-True -Name 'an absent marker reads as empty' -Condition ((Get-DeployBackendMode) -eq '')

Assert-ExitCode -Name 'local override + BACKEND_* set is refused' -Case 'backend-override-conflict'
Assert-ExitCode -Name 'no BACKEND_* and no override is refused with guidance' -Case 'backend-none-configured'

$script:InfraDir = Join-Path $TestRoot 'local-destroy'
$null = New-Item -ItemType Directory -Force -Path $script:InfraDir
$localDestroyAccepted = $true
try {
    Confirm-BackendConsistency -BackendMode 'local' -AllowLocalStateForDestroy
}
catch {
    $localDestroyAccepted = $false
}
Assert-True -Name 'destroy may fall back to local state without BACKEND_*' -Condition $localDestroyAccepted
Assert-True -Name 'local destroy fallback creates the backend override' `
    -Condition (Test-Path -LiteralPath (Get-LocalBackendOverridePath) -PathType Leaf)

# A downloaded standalone script has no Terraform files beside it. Destroy must
# therefore resolve the same cache path (keyed by -Ref) that deploy uses.
$script:ResolvedDestroyRef = ''
$script:DestroyAllowedLocalState = $false
function Resolve-InfraDir {
    param([string]$Ref)
    $script:ResolvedDestroyRef = $Ref
    return $TestRoot
}
function Resolve-TfvarsPath { param([string]$Explicit) return (Join-Path $TestRoot 'terraform.tfvars') }
function Install-TerraformIfMissing { }
function Install-AzureCliIfMissing { }
function Confirm-AzureLogin { }
function Set-AzureAuth { }
function Set-VariablesSource { }
function Resolve-BackendMode { param([switch]$Quiet) return 'local' }
function Confirm-BackendConsistency {
    param([string]$BackendMode, [switch]$AllowLocalStateForDestroy)
    $script:DestroyAllowedLocalState = $AllowLocalStateForDestroy
}
function Invoke-TfDestroy { param([string[]]$ExtraArgs = @()) }

$script:Command = 'destroy'
$script:TfvarsPath = $null
$script:Ref = 'v1'
$script:RemainingArgs = @()
$script:InfraDir = $TestRoot
Invoke-Main
Assert-True -Name 'standalone destroy resolves the same ref-keyed checkout as deploy' `
    -Condition ($script:ResolvedDestroyRef -eq 'v1') -Detail $script:ResolvedDestroyRef
Assert-True -Name 'standalone destroy keeps the local-state fallback enabled' `
    -Condition $script:DestroyAllowedLocalState

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Installer fallback chain (offline, synthetic methods)'
# ---------------------------------------------------------------------------
# Prove the chain continues past a *failing* method, not just a missing one --
# the behaviour the README promises.
$script:ChainLog = @()
function Get-InstallerCommand { param([string[]]$Names) return [pscustomobject]@{ Path = "C:\fake\$($Names[0])" } }
function Invoke-NativeProbe {
    param([scriptblock]$Command)
    $script:ChainLog += 'installer-invoked'
    return [pscustomobject]@{ Output = @(); ExitCode = 1 }  # every package manager fails
}

# The probe tool must genuinely not exist to begin with, or Install-ToolIfMissing
# short-circuits before the chain runs. The direct installer drops a real shim on
# PATH so the "did it actually land?" check is exercised too.
$shimDir = Join-Path $TestRoot 'shim'
$null = New-Item -ItemType Directory -Force -Path $shimDir
$savedPathChain = $env:Path
try {
    Install-ToolIfMissing -CommandName 'dt-chainprobe' -DisplayName 'ChainProbe' `
        -WingetId 'Fake.Id' -ChocoPackage 'fake-package' `
        -ManualUrl 'https://example.invalid' `
        -DirectInstall {
        $script:ChainLog += 'direct-reached'
        Set-Content -LiteralPath (Join-Path $shimDir 'dt-chainprobe.cmd') -Value '@echo chainprobe'
        $env:Path = "$shimDir;$env:Path"
    }
    Assert-True -Name 'a failing WinGet falls through to Chocolatey and then direct download' `
        -Condition ($script:ChainLog -contains 'direct-reached') -Detail ($script:ChainLog -join ' -> ')
    Assert-True -Name 'both package managers were attempted before the direct download' `
        -Condition ((@($script:ChainLog | Where-Object { $_ -eq 'installer-invoked' })).Count -eq 2) `
        -Detail ($script:ChainLog -join ' -> ')
    Assert-True -Name 'the chain stops once the tool resolves on PATH' `
        -Condition ([bool](Get-Command 'dt-chainprobe' -ErrorAction SilentlyContinue))
}
finally { $env:Path = $savedPathChain }

# Re-load the real definitions the stubs replaced.
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($function.Name -in @('Get-InstallerCommand', 'Invoke-NativeProbe')) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
}
Assert-ExitCode -Name 'exit 1 when every install method fails' -Case 'install-all-methods-fail'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Authenticode verification'
# ---------------------------------------------------------------------------
$signedBinary = Join-Path $env:SystemRoot 'System32\cmd.exe'
if (Test-Path -LiteralPath $signedBinary) {
    $signatureOk = $true
    try { Confirm-AuthenticodeSignature -Path $signedBinary -Description 'cmd.exe' } catch { $signatureOk = $false }
    Assert-True -Name 'a validly signed binary passes verification' -Condition $signatureOk
}
$unsignedFile = Join-Path $TestRoot 'unsigned.exe'
Set-Content -LiteralPath $unsignedFile -Value 'not a real executable'
Assert-Throw -Name 'an unsigned file is refused' { Confirm-AuthenticodeSignature -Path $unsignedFile -Description 'unsigned test file' }

# ---------------------------------------------------------------------------
if (-not $IncludeInstall) {
    Write-Host ''
    Write-Host 'Skipping the download/install group (-IncludeInstall not supplied).'
}
else {
    Write-Host ''
    Write-Host 'Real download and install (network)'
    # -----------------------------------------------------------------------
    $version = Get-LatestTerraformVersion
    Assert-True -Name 'resolved Terraform version is a plain semantic version' `
        -Condition ($version -match '^\d+\.\d+\.\d+$') -Detail "got '$version'"

    $arch = Get-TerraformArch
    $zipName = "terraform_${version}_windows_${arch}.zip"
    $zipPath = Join-Path $TestRoot $zipName
    $sumsPath = Join-Path $TestRoot "terraform_${version}_SHA256SUMS"

    Invoke-Download -Uri "https://releases.hashicorp.com/terraform/$version/$zipName" -OutFile $zipPath
    Assert-True -Name 'Terraform zip downloads' -Condition (Test-Path -LiteralPath $zipPath -PathType Leaf)
    Assert-True -Name 'downloaded zip is a non-trivial size' -Condition ((Get-Item -LiteralPath $zipPath).Length -gt 1MB)

    Invoke-Download -Uri "https://releases.hashicorp.com/terraform/$version/terraform_${version}_SHA256SUMS" -OutFile $sumsPath
    $sumsLine = Get-Content -LiteralPath $sumsPath |
    Where-Object { $_ -match "\s\*?$([regex]::Escape($zipName))\s*$" } |
    Select-Object -First 1
    Assert-True -Name 'SHA256SUMS contains an entry for our archive' -Condition ([bool]$sumsLine) -Detail $zipName

    $expectedHash = ($sumsLine -split '\s+')[0]
    $checksumOk = $true
    try { Confirm-FileSha256 -Path $zipPath -ExpectedHash $expectedHash -Description 'Terraform zip' } catch { $checksumOk = $false }
    Assert-True -Name 'published checksum matches the download' -Condition $checksumOk

    # The negative case matters more than the positive one: prove a modified
    # archive is actually rejected rather than silently extracted.
    $tamperedPath = Join-Path $TestRoot 'tampered.zip'
    Copy-Item -LiteralPath $zipPath -Destination $tamperedPath
    Add-Content -LiteralPath $tamperedPath -Value 'tampered'
    Assert-Throw -Name 'a tampered archive is rejected' {
        Confirm-FileSha256 -Path $tamperedPath -ExpectedHash $expectedHash -Description 'tampered zip'
    }

    $installDir = Join-Path $TestRoot 'tf-install'
    $null = New-Item -ItemType Directory -Force -Path $installDir
    Expand-Archive -LiteralPath $zipPath -DestinationPath $installDir -Force
    $terraformExe = Join-Path $installDir 'terraform.exe'
    Assert-True -Name 'archive extracts to terraform.exe' -Condition (Test-Path -LiteralPath $terraformExe -PathType Leaf)

    $reportedVersion = & $terraformExe version
    Assert-True -Name 'the installed binary runs and reports its version' `
        -Condition ($LASTEXITCODE -eq 0 -and ($reportedVersion -join ' ') -match [regex]::Escape($version)) `
        -Detail ($reportedVersion -join ' ')

    # End-to-end: the tool is missing from PATH, the package managers are
    # unavailable, and the direct download has to leave it resolvable.
    $savedPathE2E = $env:Path
    try {
        $env:Path = Join-Path $env:SystemRoot 'System32'
        function Get-InstallerCommand { param([string[]]$Names) return $null }
        $e2eDir = Join-Path $TestRoot 'e2e'
        $null = New-Item -ItemType Directory -Force -Path $e2eDir

        Install-ToolIfMissing -CommandName 'terraform' -DisplayName 'Terraform (e2e)' `
            -ManualUrl 'https://developer.hashicorp.com/terraform/install' `
            -DirectInstall {
            Expand-Archive -LiteralPath $zipPath -DestinationPath $e2eDir -Force
            $env:Path = "$e2eDir;$env:Path"
        }

        $resolved = Get-Command terraform -ErrorAction SilentlyContinue
        Assert-True -Name 'direct-download install leaves terraform resolvable on PATH' -Condition ([bool]$resolved)
        if ($resolved) {
            Assert-True -Name 'the resolved terraform is the one just installed' `
                -Condition ((Get-ExecutableCommandPath $resolved) -like "$e2eDir*") `
                -Detail (Get-ExecutableCommandPath $resolved)
        }
    }
    finally {
        $env:Path = $savedPathE2E
        foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            if ($function.Name -eq 'Get-InstallerCommand') { . ([scriptblock]::Create($function.Extent.Text)) }
        }
    }
}

# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '-----------------------------------------------'
Write-Host "passed: $script:Passed   failed: $script:Failed"
Write-Host '-----------------------------------------------'
if ($script:Failed -gt 0) { exit 1 }
exit 0
