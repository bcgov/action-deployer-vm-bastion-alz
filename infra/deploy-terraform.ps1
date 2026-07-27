#!/usr/bin/env pwsh
# =============================================================================
# deploy-terraform.ps1 — Terraform operations for the bundled infra/.
# =============================================================================
# Usage (from repo root or infra/):
#   .\infra\deploy-terraform.ps1 <command> [terraform args...]
#
# Commands: init | plan | apply | destroy | validate | fmt | output | refresh | state | deploy
#
# `deploy` is a one-step command for a developer workstation: installs
# Terraform/Azure CLI/Git if missing, logs in to Azure if needed, resolves a
# terraform.tfvars file from anywhere on disk (-TfvarsPath), auto-selects a
# Terraform backend (azurerm if BACKEND_* env vars are set, otherwise local
# state on this machine), then runs init + apply. It also works when this
# script is downloaded standalone with no repo clone -- see README.md ->
# "Local deployment" -> "One-step local deploy".
#
# This is the PowerShell equivalent of deploy-terraform.sh for local use on
# Windows without Git Bash/WSL. Behavior matches the bash script (`deploy` is
# PowerShell-only); see README.md -> "Local deployment" for the full walkthrough.
#
# Auto-install: Terraform, the Azure CLI, and (for standalone `deploy` runs)
# Git are installed automatically if missing. Each tool is attempted via WinGet,
# then Chocolatey, then a direct download -- every method is tried in turn until
# one leaves the tool on PATH, so a failing WinGet no longer ends the run.
# Direct downloads are verified before use: the Terraform zip against
# HashiCorp's published SHA256SUMS, the Azure CLI MSI and Git installer against
# their Authenticode signatures. Machine-wide installs can prompt for elevation
# -- run from an elevated ("Run as Administrator") PowerShell to avoid
# interruptions.
#
# Environment:
#   CI=true                  auto-approve apply/destroy, no interactive prompts
#   ARM_USE_OIDC=true        use OIDC (CI); otherwise Azure CLI auth is used
#   BACKEND_RESOURCE_GROUP / BACKEND_STORAGE_ACCOUNT / BACKEND_CONTAINER_NAME /
#   BACKEND_STATE_KEY        azurerm remote-state backend config; omit all to
#                            let `deploy` fall back to local Terraform state
#   TF_VAR_*                 standard Terraform variables
#
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('init', 'plan', 'apply', 'destroy', 'validate', 'fmt', 'output', 'refresh', 'state', 'deploy')]
    [string]$Command,

    # Path to a terraform.tfvars file anywhere on disk (absolute or relative).
    # Defaults to infra/terraform.tfvars (today's behavior) when omitted.
    [string]$TfvarsPath,

    # Only 'local' exists today. Explicit and self-documenting so a future
    # non-breaking addition (e.g. a remote-exec mode) has a home. Logged on
    # every `deploy` so the selected mode is visible in the run output.
    [ValidateSet('local')]
    [string]$Mode = 'local',

    # Branch or tag `deploy` self-clones when run standalone, i.e. this script
    # has no infra/ checkout next to it (downloaded directly via
    # raw.githubusercontent.com rather than as part of a repo clone).
    [string]$Ref = 'main',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when the script is piped into iex rather than run with
# -File. Every path below is built from it, so fail loudly and early instead of
# emitting confusing Join-Path errors.
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    [Console]::Error.WriteLine(
        "[deploy] ERROR: this script must be run from a file (e.g. 'pwsh -File .\deploy-terraform.ps1 deploy'), not piped into iex.")
    exit 1
}

$InfraDir = $PSScriptRoot
$TfvarsFile = $null # resolved in Invoke-Main by Resolve-TfvarsPath

$BackendResourceGroup = if ($env:BACKEND_RESOURCE_GROUP) { $env:BACKEND_RESOURCE_GROUP } else { '' }
$BackendStorageAccount = if ($env:BACKEND_STORAGE_ACCOUNT) { $env:BACKEND_STORAGE_ACCOUNT } else { '' }
$BackendContainerName = if ($env:BACKEND_CONTAINER_NAME) { $env:BACKEND_CONTAINER_NAME } else { 'tfstate' }
$BackendStateKey = if ($env:BACKEND_STATE_KEY) { $env:BACKEND_STATE_KEY } else { '' }

$script:TfvarsArgs = @()
# Backend the current command will initialize with; set in Invoke-Main.
$script:BackendMode = 'azurerm'

function Test-CiMode { return $env:CI -eq 'true' }

# Logs go to stderr, matching deploy-terraform.sh's log(). This keeps
# `deploy-terraform.ps1 output > file` capturing only Terraform's output, the
# way the bash script behaves -- Write-Host renders straight to the host and is
# dropped by both > and 2> redirection.
function Write-DeployLog {
    param([string]$Msg)
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    [Console]::Error.WriteLine("$timestamp [deploy] $Msg")
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE"
    }
}

# Runs a native command whose failure is expected and must be inspected rather
# than thrown. Windows PowerShell 5.1 turns a native command's stderr into a
# terminating NativeCommandError when $ErrorActionPreference is 'Stop' and
# stderr is redirected, and PowerShell 7 does the same for non-zero exit codes
# when $PSNativeCommandUseErrorActionPreference is enabled in a user profile.
# Either would kill the script before its exit code could be checked -- e.g.
# `az account show` failing simply because the user is not logged in yet.
# Mirrors Invoke-AzProbe in bastion-consumer-scripts/bastion-proxy.ps1.
function Invoke-NativeProbe {
    param([Parameter(Mandatory)][scriptblock]$Command)

    $nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $previousErrorActionPreference = $ErrorActionPreference
    if ($nativeErrorPreference) {
        $previousNativeErrorPreference = $nativeErrorPreference.Value
        $script:PSNativeCommandUseErrorActionPreference = $false
    }
    $script:ErrorActionPreference = 'Continue'

    try {
        $output = & $Command 2>&1
        $exitVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        $exitCode = if ($exitVariable -and $null -ne $exitVariable.Value) { $exitVariable.Value } else { 0 }

        return [pscustomobject]@{
            Output   = @($output)
            ExitCode = $exitCode
        }
    }
    finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
        if ($nativeErrorPreference) {
            $script:PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ExecutableCommandPath {
    param([Parameter(Mandatory)]$CommandInfo)

    foreach ($propertyName in 'Path', 'Source', 'Definition') {
        $propertyValue = $CommandInfo.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($propertyValue)) {
            return $propertyValue
        }
    }
    return $null
}

function Get-InstallerCommand {
    param([Parameter(Mandatory)][string[]]$Names)
    return (Get-Command @Names -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Rebuilds the process PATH from the process, user and machine scopes so a
# freshly installed tool is resolvable without restarting the shell.
# Each -split produces its own array; they must be concatenated into one flat
# list before joining. Collecting them with @(a, b, c) would instead build an
# array *of arrays*, which -join renders as "System.String[];System.String[]..."
# and destroys the PATH for the rest of the process.
function Update-ProcessPathFromEnvironment {
    $pathEntries = @()
    foreach ($source in @(
            $env:Path,
            [Environment]::GetEnvironmentVariable('Path', 'User'),
            [Environment]::GetEnvironmentVariable('Path', 'Machine'))) {
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            $pathEntries += ($source -split ';')
        }
    }

    $env:Path = (($pathEntries |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique) -join ';')
}

# Windows PowerShell 5.1 inherits the .NET default TLS policy, which on some
# hosts still excludes TLS 1.2 -- every download below would fail with "Could
# not create SSL/TLS secure channel". Its progress bar also slows large
# downloads by roughly an order of magnitude, and -UseBasicParsing avoids a
# dependency on Internet Explorer's engine.
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

function Invoke-DownloadString {
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSec = 15)

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        return (Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing)
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

# Installers are downloaded over the network and then executed, often from an
# elevated shell. Refuse to run anything whose publisher signature does not
# validate.
function Confirm-AuthenticodeSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "$Description failed Authenticode verification (status: $($signature.Status)). Refusing to execute it."
    }
    $subject = $signature.SignerCertificate.Subject -replace ',.*$', ''
    Write-DeployLog "$Description signature verified ($subject)."
}

function Confirm-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$Description
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedHash.ToUpperInvariant()) {
        throw "$Description checksum mismatch (expected $($ExpectedHash.ToUpperInvariant()), got $actual). Refusing to use it."
    }
    Write-DeployLog "$Description checksum verified (SHA256 $actual)."
}

# Tries WinGet, then Chocolatey, then the supplied direct-download installer.
# Each method is attempted in turn and a failure only moves on to the next one,
# so a broken or unavailable WinGet no longer ends the run. A method counts as
# successful only once the tool actually resolves on PATH.
function Install-ToolIfMissing {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$WingetId,
        [string]$ChocoPackage,
        [Parameter(Mandatory)][scriptblock]$DirectInstall,
        [Parameter(Mandatory)][string]$ManualUrl
    )

    if (Test-CommandAvailable $CommandName) {
        Write-DeployLog "$DisplayName ready: $(Get-ExecutableCommandPath (Get-Command $CommandName))"
        return
    }

    Write-DeployLog "$DisplayName is not installed. Attempting installation..."

    $methods = @()
    if ($WingetId) {
        $methods += @{
            Name   = 'WinGet'
            Action = {
                $wingetCommand = Get-InstallerCommand -Names @('winget.exe', 'winget')
                if (-not $wingetCommand) { throw 'WinGet is not available on this machine.' }
                $wingetPath = Get-ExecutableCommandPath $wingetCommand
                $result = Invoke-NativeProbe {
                    & $wingetPath install --exact --id $WingetId --accept-source-agreements --accept-package-agreements
                }
                if ($result.ExitCode -ne 0) { throw "WinGet exited with code $($result.ExitCode)." }
            }
        }
    }
    if ($ChocoPackage) {
        $methods += @{
            Name   = 'Chocolatey'
            Action = {
                $chocoCommand = Get-InstallerCommand -Names @('choco.exe', 'choco')
                if (-not $chocoCommand) { throw 'Chocolatey is not available on this machine.' }
                $chocoPath = Get-ExecutableCommandPath $chocoCommand
                $result = Invoke-NativeProbe { & $chocoPath install $ChocoPackage -y }
                if ($result.ExitCode -ne 0) { throw "Chocolatey exited with code $($result.ExitCode)." }
            }
        }
    }
    $methods += @{ Name = 'direct download'; Action = $DirectInstall }

    foreach ($method in $methods) {
        Write-DeployLog "Installing $DisplayName with $($method.Name)..."
        try {
            & $method.Action | Out-Null
        }
        catch {
            Write-DeployLog "WARN: $($method.Name) could not install $DisplayName ($($_.Exception.Message))"
            continue
        }

        Update-ProcessPathFromEnvironment
        if (Test-CommandAvailable $CommandName) {
            Write-DeployLog "$DisplayName ready: $(Get-ExecutableCommandPath (Get-Command $CommandName))"
            return
        }
        Write-DeployLog "WARN: $($method.Name) finished but $CommandName is still not on PATH; trying the next method."
    }

    Write-DeployLog "ERROR: $DisplayName could not be installed automatically. Re-run in a fresh shell or install manually from $ManualUrl"
    exit 1
}

function Install-AzureCliIfMissing {
    Install-ToolIfMissing -CommandName 'az' -DisplayName 'Azure CLI' `
        -WingetId 'Microsoft.AzureCLI' -ChocoPackage 'azure-cli' `
        -ManualUrl 'https://learn.microsoft.com/cli/azure/install-azure-cli' `
        -DirectInstall {
        $installerPath = Join-Path $env:TEMP 'AzureCLI.msi'
        try {
            Invoke-Download -Uri 'https://aka.ms/installazurecliwindows' -OutFile $installerPath
            Confirm-AuthenticodeSignature -Path $installerPath -Description 'Azure CLI MSI installer'
            $installerProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $installerPath, '/passive', '/norestart') -Wait -PassThru
            if ($installerProcess.ExitCode -notin @(0, 3010)) {
                throw "Azure CLI MSI installer returned exit code $($installerProcess.ExitCode)."
            }
        }
        finally {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-GitIfMissing {
    Install-ToolIfMissing -CommandName 'git' -DisplayName 'Git' `
        -WingetId 'Git.Git' -ChocoPackage 'git' `
        -ManualUrl 'https://git-scm.com/downloads' `
        -DirectInstall {
        $installerPath = Join-Path $env:TEMP 'GitInstaller.exe'
        try {
            $release = Invoke-DownloadString -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest'
            $asset = $release.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1
            if (-not $asset) { throw 'Could not find a 64-bit Git for Windows installer asset.' }
            Invoke-Download -Uri $asset.browser_download_url -OutFile $installerPath
            Confirm-AuthenticodeSignature -Path $installerPath -Description 'Git for Windows installer'
            $installerProcess = Start-Process -FilePath $installerPath -ArgumentList @('/VERYSILENT', '/NORESTART') -Wait -PassThru
            if ($installerProcess.ExitCode -ne 0) {
                throw "Git installer returned exit code $($installerProcess.ExitCode)."
            }
        }
        finally {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TerraformArch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    return 'amd64'
}

function Get-LatestTerraformVersion {
    param([string]$FallbackVersion = '1.12.0')
    try {
        $response = Invoke-DownloadString -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' -TimeoutSec 10
        # The version is interpolated into a download URL and a file name, so
        # only accept a plain semantic version -- never a path fragment from a
        # response we do not control.
        if ($response.current_version -match '^\d+\.\d+\.\d+$') { return $response.current_version }
        Write-DeployLog "WARN: checkpoint API returned an unexpected Terraform version; falling back to $FallbackVersion"
    }
    catch {
        Write-DeployLog "WARN: Could not resolve latest Terraform version ($($_.Exception.Message)); falling back to $FallbackVersion"
    }
    return $FallbackVersion
}

function Install-TerraformIfMissing {
    Install-ToolIfMissing -CommandName 'terraform' -DisplayName 'Terraform' `
        -WingetId 'HashiCorp.Terraform' -ChocoPackage 'terraform' `
        -ManualUrl 'https://developer.hashicorp.com/terraform/install' `
        -DirectInstall {
        $version = Get-LatestTerraformVersion
        $arch = Get-TerraformArch
        $installDir = Join-Path $env:LocalAppData 'Programs\Terraform'
        $zipName = "terraform_${version}_windows_${arch}.zip"
        $zipPath = Join-Path $env:TEMP $zipName
        $sumsPath = Join-Path $env:TEMP "terraform_${version}_SHA256SUMS"
        $downloadUrl = "https://releases.hashicorp.com/terraform/${version}/${zipName}"
        $sumsUrl = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_SHA256SUMS"

        Write-DeployLog "Installing Terraform $version ($arch) from HashiCorp releases..."
        try {
            New-Item -ItemType Directory -Force -Path $installDir | Out-Null
            Invoke-Download -Uri $downloadUrl -OutFile $zipPath

            Invoke-Download -Uri $sumsUrl -OutFile $sumsPath
            $sumsLine = Get-Content -LiteralPath $sumsPath |
            Where-Object { $_ -match "\s\*?$([regex]::Escape($zipName))\s*$" } |
            Select-Object -First 1
            if (-not $sumsLine) { throw "No SHA256SUMS entry found for $zipName." }
            Confirm-FileSha256 -Path $zipPath -ExpectedHash (($sumsLine -split '\s+')[0]) -Description "Terraform $version zip"

            Expand-Archive -LiteralPath $zipPath -DestinationPath $installDir -Force
        }
        finally {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $sumsPath -Force -ErrorAction SilentlyContinue
        }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $userPathParts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($userPathParts -notcontains $installDir) {
            Write-DeployLog "Adding $installDir to your user PATH (persists for future shells)."
            [Environment]::SetEnvironmentVariable('Path', (($userPathParts + $installDir) -join ';'), 'User')
        }
    }
}

function Test-InfraCheckoutPresent {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path 'main.tf') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'backend.tf') -PathType Leaf)
}

# The ref is passed to git and used as a directory name. Reject anything that
# could be read as a git option (--upload-pack=... is a command-execution
# vector) or that escapes the cache root.
function Confirm-RefIsSafe {
    param([Parameter(Mandatory)][string]$Ref)

    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref -like '*..*') {
        Write-DeployLog "ERROR: -Ref '$Ref' is not a valid branch or tag name. Use letters, digits, '.', '_', '-' and '/' only."
        exit 1
    }
}

# Serializes runs that share a directory (the standalone cache checkout, the
# generated backend override and the backend-mode marker). Terraform's own lock
# protects the state file but not these.
function Enter-DeployLock {
    param([Parameter(Mandatory)][string]$Key)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant()))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }

    $mutex = New-Object System.Threading.Mutex($false, "Local\deploy-terraform-$($hash.Substring(0, 32))")
    try {
        if (-not $mutex.WaitOne(0)) {
            Write-DeployLog "Another deploy-terraform run is using '$Key'; waiting for it to finish..."
            if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(30))) {
                Write-DeployLog "ERROR: timed out waiting for the other run to release '$Key'."
                exit 1
            }
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # The previous holder exited without releasing; ownership passes to us.
        Write-DeployLog "WARN: a previous deploy-terraform run exited without releasing '$Key'; continuing."
    }
    return $mutex
}

function Exit-DeployLock {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { Write-DeployLog "WARN: could not release the run lock ($($_.Exception.Message))." }
    $Mutex.Dispose()
}

# `deploy` must work when this script is downloaded standalone (e.g. via
# raw.githubusercontent.com, no repo clone) -- self-clone the repo with Git so
# the rest of infra/ (main.tf, modules/, etc.) is available to run Terraform
# against. Every other command keeps assuming $PSScriptRoot is a real
# checkout, unchanged.
function Resolve-InfraDir {
    param([Parameter(Mandatory)][string]$Ref)

    if (Test-InfraCheckoutPresent -Path $PSScriptRoot) {
        return $PSScriptRoot
    }

    Confirm-RefIsSafe -Ref $Ref
    Write-DeployLog 'Standalone script detected (no infra/ checkout next to deploy-terraform.ps1); self-bootstrapping one with Git...'
    if ($Ref -eq 'main') {
        Write-DeployLog "WARN: -Ref defaults to 'main', which moves over time -- two runs of the same command can deploy different infrastructure. Pass -Ref <tag> (e.g. -Ref v1) to pin a release."
    }
    Install-GitIfMissing

    $repoUrl = 'https://github.com/bcgov/action-deployer-vm-bastion-alz.git'
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'bcgov\action-deployer-vm-bastion-alz'
    $repoDir = Join-Path $cacheRoot $Ref

    $lock = Enter-DeployLock -Key $repoDir
    try {
        $isNewCheckout = -not (Test-Path -LiteralPath (Join-Path $repoDir '.git') -PathType Container)

        if ($isNewCheckout) {
            Write-DeployLog "Cloning $repoUrl (ref: $Ref) into $repoDir..."
            New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
        }
        else {
            Write-DeployLog "Updating cached checkout ($repoDir, ref: $Ref)..."
        }

        Push-Location -LiteralPath $repoDir
        try {
            if ($isNewCheckout) {
                Invoke-Native -FilePath 'git' -ArgumentList @('init', '-q')
                Invoke-Native -FilePath 'git' -ArgumentList @('remote', 'add', 'origin', $repoUrl)
            }
            # '--' stops git option parsing so a ref can never be read as a flag.
            Invoke-Native -FilePath 'git' -ArgumentList @('fetch', '--depth', '1', 'origin', '--', $Ref)
            Invoke-Native -FilePath 'git' -ArgumentList @('checkout', '--force', 'FETCH_HEAD')
        }
        finally {
            Pop-Location
        }
    }
    finally {
        Exit-DeployLock -Mutex $lock
    }

    $resolvedInfraDir = Join-Path $repoDir 'infra'
    if (-not (Test-InfraCheckoutPresent -Path $resolvedInfraDir)) {
        Write-DeployLog "ERROR: checkout at $repoDir does not contain the expected infra/ Terraform files (ref: $Ref)."
        exit 1
    }

    Write-DeployLog "Standalone mode: using self-bootstrapped checkout at $resolvedInfraDir"
    return $resolvedInfraDir
}

function Confirm-AzureLogin {
    # Probed rather than run directly: a signed-out `az account show` writes to
    # stderr and exits non-zero, which would otherwise terminate the script
    # before the fallback below could run.
    $probe = Invoke-NativeProbe { az account show }
    if ($probe.ExitCode -ne 0) {
        if (Test-CiMode) {
            Write-DeployLog 'CI mode: assuming OIDC/service-principal authentication'
        }
        else {
            Write-DeployLog "Not logged in to Azure; running 'az login'..."
            az login
            if ($LASTEXITCODE -ne 0) {
                Write-DeployLog 'ERROR: az login failed.'
                exit 1
            }
        }
    }
}

function Get-TfvarsSubscriptionId {
    if (-not (Test-Path -LiteralPath $TfvarsFile -PathType Leaf)) { return '' }
    $match = Select-String -LiteralPath $TfvarsFile -Pattern '^\s*subscription_id\s*=\s*"([^"]*)"' | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return ''
}

# -TfvarsPath can point anywhere on disk, not just infra/terraform.tfvars --
# needed for `deploy`, honored by every command. Omit it to keep today's
# default (infra/terraform.tfvars) unchanged.
function Resolve-TfvarsPath {
    param([string]$Explicit)

    if ($Explicit) {
        $candidate = $Explicit
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path (Get-Location).ProviderPath $candidate
        }
        # -LiteralPath throughout: '[' and ']' are legal in Windows paths but
        # are wildcards to -Path, which would silently report a real file as
        # missing -- and, at the call site in Invoke-Main, silently skip the
        # REPLACE_ME check entirely.
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Write-DeployLog "ERROR: -TfvarsPath '$Explicit' was not found. Create one first: copy examples/local.tfvars from the repo (or download it directly: https://raw.githubusercontent.com/bcgov/action-deployer-vm-bastion-alz/main/examples/local.tfvars), fill in every REPLACE_ME value, then re-run with -TfvarsPath pointing at your copy."
            exit 1
        }
        return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }

    return (Join-Path $InfraDir 'terraform.tfvars')
}

function Set-AzureAuth {
    $sub = if ($env:TF_VAR_subscription_id) { $env:TF_VAR_subscription_id } else { '' }
    if (-not $sub) { $sub = Get-TfvarsSubscriptionId }
    if ($sub) {
        az account set --subscription $sub
        if ($LASTEXITCODE -ne 0) {
            Write-DeployLog "ERROR: could not select subscription '$sub'. Check the id and your access to it."
            exit 1
        }
        $env:ARM_SUBSCRIPTION_ID = $sub
    }
    else {
        $resolved = az account show --query id -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolved)) {
            Write-DeployLog "ERROR: no subscription id was supplied and none could be read from the current Azure login. Set TF_VAR_subscription_id, add subscription_id to your tfvars, or run 'az account set --subscription <id>'."
            exit 1
        }
        $env:ARM_SUBSCRIPTION_ID = $resolved
    }

    # Only export when non-empty: an empty ARM_TENANT_ID / ARM_CLIENT_ID is
    # worse than an absent one, because the provider treats it as configured.
    if ($env:TF_VAR_tenant_id) { $env:ARM_TENANT_ID = $env:TF_VAR_tenant_id }

    $useOidc = ($env:ARM_USE_OIDC -eq 'true') -or ($env:TF_VAR_use_oidc -eq 'true')
    if ($useOidc) {
        $clientId = if ($env:TF_VAR_client_id) { $env:TF_VAR_client_id } elseif ($env:ARM_CLIENT_ID) { $env:ARM_CLIENT_ID } else { '' }
        if (-not $clientId) {
            Write-DeployLog 'ERROR: OIDC authentication was requested but no client id is available. Set TF_VAR_client_id or ARM_CLIENT_ID.'
            exit 1
        }
        $env:ARM_USE_OIDC = 'true'
        $env:ARM_CLIENT_ID = $clientId
        Write-DeployLog 'Using OIDC authentication'
    }
    else {
        $env:ARM_USE_CLI = 'true'
        Write-DeployLog 'Using Azure CLI authentication'
    }
}

# Strips HCL comments (#, // and /* */) from a line while respecting quoted
# strings, so a value like "https://host/REPLACE_ME" is not mistaken for a
# comment and a commented-out template line is not mistaken for a real value.
function Remove-HclComment {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][ref]$InBlockComment
    )

    $result = New-Object System.Text.StringBuilder
    $inString = $false
    $i = 0

    while ($i -lt $Line.Length) {
        $ch = $Line[$i]
        $next = if ($i + 1 -lt $Line.Length) { $Line[$i + 1] } else { [char]0 }

        if ($InBlockComment.Value) {
            if ($ch -eq '*' -and $next -eq '/') { $InBlockComment.Value = $false; $i += 2 } else { $i++ }
            continue
        }
        if ($inString) {
            [void]$result.Append($ch)
            if ($ch -eq '\') {
                if ($i + 1 -lt $Line.Length) { [void]$result.Append($next) }
                $i += 2
                continue
            }
            if ($ch -eq '"') { $inString = $false }
            $i++
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$result.Append($ch); $i++; continue }
        if ($ch -eq '#') { break }
        if ($ch -eq '/' -and $next -eq '/') { break }
        if ($ch -eq '/' -and $next -eq '*') { $InBlockComment.Value = $true; $i += 2; continue }

        [void]$result.Append($ch)
        $i++
    }

    return $result.ToString()
}

function Test-TfvarsNoPlaceholder {
    param([Parameter(Mandatory)][string]$Path)

    # Find non-comment lines that still contain the REPLACE_ME sentinel value.
    # Catches string values ("REPLACE_ME"), list items (["REPLACE_ME"]), and
    # anything in between -- before any Azure or Terraform call is made.
    # $offending is built as a real array: with exactly one match a pipeline
    # would yield a bare string, and $string.Count is an error under
    # Set-StrictMode -Version Latest.
    $offending = @()
    $inBlockComment = $false
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $code = Remove-HclComment -Line $line -InBlockComment ([ref]$inBlockComment)
        if ($code -match 'REPLACE_ME') { $offending += $line }
    }

    if ($offending.Count -eq 0) { return }

    Write-DeployLog "ERROR: $($offending.Count) value(s) in '$Path' still contain the REPLACE_ME placeholder. Replace them with real values before deploying:"
    foreach ($line in $offending) {
        Write-DeployLog "  $($line.Trim())"
    }
    Write-DeployLog "See README.md -> 'Local tfvars fields' for where to find each value."
    exit 1
}

function Set-VariablesSource {
    if (Test-Path -LiteralPath $TfvarsFile -PathType Leaf) {
        $script:TfvarsArgs = @("-var-file=$TfvarsFile")
        Write-DeployLog "Using tfvars: $TfvarsFile"
        return
    }

    $required = @('TF_VAR_app_name', 'TF_VAR_subscription_id', 'TF_VAR_tenant_id',
        'TF_VAR_location', 'TF_VAR_resource_group_name', 'TF_VAR_vnet_name',
        'TF_VAR_vnet_resource_group_name', 'TF_VAR_vnet_address_space')
    $missing = @()
    foreach ($v in $required) {
        $value = [Environment]::GetEnvironmentVariable($v)
        if ([string]::IsNullOrEmpty($value)) { $missing += $v }
    }
    if ($missing.Count -gt 0) {
        Write-DeployLog "ERROR: missing required environment variables: $($missing -join ' ')"
        exit 1
    }
}

function Invoke-TfInit {
    param(
        [string[]]$ExtraArgs = @(),
        [ValidateSet('azurerm', 'local')][string]$BackendMode = $script:BackendMode
    )

    Push-Location -LiteralPath $InfraDir
    try {
        $initArgs = @('init', '-upgrade')
        if (Test-CiMode) { $initArgs += '-input=false' }
        if ($BackendMode -eq 'azurerm') {
            Write-DeployLog "Initializing Terraform (backend: ${BackendStorageAccount}/${BackendContainerName}/${BackendStateKey})"
            $useOidcFlag = if ($env:ARM_USE_OIDC) { $env:ARM_USE_OIDC } else { 'false' }
            $initArgs += @(
                "-backend-config=resource_group_name=$BackendResourceGroup",
                "-backend-config=storage_account_name=$BackendStorageAccount",
                "-backend-config=container_name=$BackendContainerName",
                "-backend-config=key=$BackendStateKey",
                "-backend-config=use_oidc=$useOidcFlag"
            )
        }
        else {
            Write-DeployLog 'Initializing Terraform (backend: local state file, infra/terraform.tfstate -- not shared, this machine only)'
        }
        $initArgs += $ExtraArgs
        Invoke-Native -FilePath 'terraform' -ArgumentList $initArgs
    }
    finally {
        Pop-Location
    }
}

function Confirm-Initialized {
    Push-Location -LiteralPath $InfraDir
    try {
        $isInitialized = (Test-Path -LiteralPath '.terraform' -PathType Container) -and
            (Test-Path -LiteralPath '.terraform.lock.hcl' -PathType Leaf)
        if (-not $isInitialized) { Invoke-TfInit }
    }
    finally {
        Pop-Location
    }
}

function Invoke-TfPlan {
    param([string[]]$ExtraArgs = @())

    Confirm-Initialized
    Push-Location -LiteralPath $InfraDir
    try {
        Invoke-Native -FilePath 'terraform' -ArgumentList (@('plan') + $script:TfvarsArgs + $ExtraArgs)
    }
    finally {
        Pop-Location
    }
}

function Invoke-TfApply {
    param([string[]]$ExtraArgs = @())

    if (Test-CiMode) { Invoke-TfInit } else { Confirm-Initialized }
    Push-Location -LiteralPath $InfraDir
    try {
        $applyArgs = @('apply') + $script:TfvarsArgs
        if (Test-CiMode) { $applyArgs += '-auto-approve' }
        $applyArgs += $ExtraArgs
        Invoke-Native -FilePath 'terraform' -ArgumentList $applyArgs
        Write-DeployLog 'Apply complete; outputs:'
        Invoke-Native -FilePath 'terraform' -ArgumentList @('output')
    }
    finally {
        Pop-Location
    }
}

function Resolve-BackendMode {
    param([switch]$Quiet)

    # azurerm when all required BACKEND_* env vars are set (the same remote
    # state CI uses), otherwise local Terraform state so `deploy` never
    # hard-fails just because no shared backend was configured.
    $hasRemoteConfig = [bool]($BackendResourceGroup -and $BackendStorageAccount -and $BackendStateKey)
    if ($hasRemoteConfig) { return 'azurerm' }

    if (-not $Quiet) {
        Write-DeployLog 'WARN: BACKEND_* environment variables are not fully set -- falling back to LOCAL Terraform state (infra/terraform.tfstate).'
        Write-DeployLog 'WARN: Local state lives only on this machine and is NOT shared. Do not use this mode for team/shared deployments -- set BACKEND_RESOURCE_GROUP, BACKEND_STORAGE_ACCOUNT, and BACKEND_STATE_KEY to use the shared azurerm backend instead.'
    }
    return 'local'
}

function Get-LocalBackendOverridePath {
    return (Join-Path $InfraDir 'local_backend_override.tf')
}

function Set-LocalBackendOverride {
    param(
        [Parameter(Mandatory)][string]$InfraPath,
        [Parameter(Mandatory)][ValidateSet('azurerm', 'local')][string]$BackendMode
    )

    $overridePath = Join-Path $InfraPath 'local_backend_override.tf'
    if ($BackendMode -eq 'local') {
        Set-Content -LiteralPath $overridePath -Encoding utf8 -Value @'
# Generated by deploy-terraform.ps1 (no BACKEND_* env vars set) -- overrides
# backend.tf's `backend "azurerm" {}` with local state for this machine only.
# Safe to delete; git-ignored; regenerated automatically on the next `deploy`.
terraform {
  backend "local" {}
}
'@
    }
    else {
        Remove-Item -LiteralPath $overridePath -Force -ErrorAction SilentlyContinue
    }
}

# Every command other than `deploy` inherits whatever backend the directory was
# last left in. Without this check, running `apply` after a local-state `deploy`
# silently keeps using local state even once BACKEND_* is set, because
# Confirm-Initialized sees .terraform/ and skips init entirely.
function Confirm-BackendConsistency {
    param([Parameter(Mandatory)][ValidateSet('azurerm', 'local')][string]$BackendMode)

    $overridePath = Get-LocalBackendOverridePath
    $overridePresent = Test-Path -LiteralPath $overridePath -PathType Leaf

    if ($overridePresent -and $BackendMode -eq 'azurerm') {
        Write-DeployLog "ERROR: '$overridePath' pins this directory to LOCAL Terraform state, but BACKEND_* environment variables select the shared azurerm backend."
        Write-DeployLog 'Refusing to continue: the two disagree, and running anyway would silently use local state.'
        Write-DeployLog 'Resolve it by either:'
        Write-DeployLog '  - unsetting BACKEND_RESOURCE_GROUP / BACKEND_STORAGE_ACCOUNT / BACKEND_STATE_KEY to keep local state, or'
        Write-DeployLog '  - migrating to the shared backend, then deleting the override file:'
        Write-DeployLog "      terraform -chdir='$InfraDir' init -migrate-state -backend-config=resource_group_name=... -backend-config=storage_account_name=... -backend-config=container_name=... -backend-config=key=..."
        exit 1
    }

    if (-not $overridePresent -and $BackendMode -eq 'local') {
        Write-DeployLog 'ERROR: no BACKEND_* environment variables are set, so there is no backend to initialize against.'
        Write-DeployLog 'Set BACKEND_RESOURCE_GROUP, BACKEND_STORAGE_ACCOUNT and BACKEND_STATE_KEY to use the shared azurerm backend,'
        Write-DeployLog "or run '.\deploy-terraform.ps1 deploy', which falls back to local state automatically."
        exit 1
    }

    if ($overridePresent) {
        Write-DeployLog 'Effective backend: LOCAL state (infra/terraform.tfstate -- this machine only, not shared).'
    }
    else {
        Write-DeployLog "Effective backend: azurerm (${BackendStorageAccount}/${BackendContainerName}/${BackendStateKey})"
    }
}

function Get-DeployBackendModeMarkerPath {
    return (Join-Path $InfraDir '.deploy-backend-mode')
}

function Get-DeployBackendMode {
    $markerPath = Get-DeployBackendModeMarkerPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return '' }
    $previousMode = Get-Content -LiteralPath $markerPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $previousMode) { return '' }
    return $previousMode.Trim()
}

function Set-DeployBackendModeMarker {
    param([Parameter(Mandatory)][string]$BackendMode)
    Set-Content -LiteralPath (Get-DeployBackendModeMarkerPath) -Value $BackendMode -Encoding utf8 -NoNewline
}

function Invoke-TfDeploy {
    param([string[]]$ExtraArgs = @())

    $backendMode = Resolve-BackendMode

    # `terraform init -reconfigure` ignores saved configuration -- it does NOT
    # migrate state. Switching backends with it would silently orphan the
    # existing state and make the apply that follows re-create every resource,
    # so stop and let the operator decide instead.
    $previousMode = Get-DeployBackendMode
    if ($previousMode -and $previousMode -ne $backendMode) {
        Write-DeployLog "ERROR: the Terraform backend for '$InfraDir' changed since the last deploy ($previousMode -> $backendMode)."
        Write-DeployLog 'Existing state is NOT migrated automatically, and continuing would re-create resources that already exist.'
        Write-DeployLog 'Choose one:'
        Write-DeployLog "  - migrate the existing state:  terraform -chdir='$InfraDir' init -migrate-state [-backend-config=...]"
        Write-DeployLog "  - or start fresh here: delete '$(Join-Path $InfraDir '.terraform')' and '$(Get-DeployBackendModeMarkerPath)'"
        Write-DeployLog "  - or restore the previous backend configuration ($previousMode) and re-run."
        exit 1
    }

    $lock = Enter-DeployLock -Key $InfraDir
    try {
        Set-LocalBackendOverride -InfraPath $InfraDir -BackendMode $backendMode

        Push-Location -LiteralPath $InfraDir
        try {
            Invoke-TfInit -BackendMode $backendMode
            Set-DeployBackendModeMarker -BackendMode $backendMode

            $applyArgs = @('apply') + $script:TfvarsArgs + $ExtraArgs
            Invoke-Native -FilePath 'terraform' -ArgumentList $applyArgs
            Write-DeployLog 'Deploy complete; outputs:'
            Invoke-Native -FilePath 'terraform' -ArgumentList @('output')
        }
        finally {
            Pop-Location
        }
    }
    finally {
        Exit-DeployLock -Mutex $lock
    }
}

function Invoke-TfDestroy {
    param([string[]]$ExtraArgs = @())

    Confirm-Initialized
    Push-Location -LiteralPath $InfraDir
    try {
        $destroyArgs = @('destroy') + $script:TfvarsArgs
        if (Test-CiMode) {
            $destroyArgs += '-auto-approve'
        }
        else {
            $confirm = Read-Host "This will DESTROY infrastructure. Type 'yes' to continue"
            if ($confirm -ne 'yes') {
                Write-DeployLog 'Destroy cancelled'
                exit 0
            }
        }
        $destroyArgs += $ExtraArgs
        Invoke-Native -FilePath 'terraform' -ArgumentList $destroyArgs
    }
    finally {
        Pop-Location
    }
}

function Invoke-Main {
    if (Test-CiMode) { Write-DeployLog 'Running in CI mode (auto-approve enabled)' }

    if ($Command -eq 'deploy') {
        # `deploy` is an interactive workstation command: it deliberately never
        # passes -auto-approve, so under CI its apply would block on a prompt
        # that can never be answered.
        if (Test-CiMode) {
            Write-DeployLog "ERROR: 'deploy' is a local workstation command and cannot run under CI=true (its apply always prompts for confirmation)."
            Write-DeployLog "Use 'init' followed by 'apply' in CI -- those auto-approve when CI=true."
            exit 1
        }
        Write-DeployLog "Execution mode: $Mode"
        $script:InfraDir = Resolve-InfraDir -Ref $Ref
    }

    $script:TfvarsFile = Resolve-TfvarsPath -Explicit $TfvarsPath
    if (Test-Path -LiteralPath $script:TfvarsFile -PathType Leaf) {
        Test-TfvarsNoPlaceholder -Path $script:TfvarsFile
    }

    Install-TerraformIfMissing

    switch ($Command) {
        { $_ -in @('fmt', 'validate') } { } # no Azure auth or backend needed
        default {
            Install-AzureCliIfMissing
            Confirm-AzureLogin
            Set-AzureAuth
            Set-VariablesSource

            # Invoke-TfDeploy resolves and reconciles the backend itself; every
            # other command must not silently inherit a stale one.
            $script:BackendMode = Resolve-BackendMode -Quiet
            if ($Command -ne 'deploy') {
                Confirm-BackendConsistency -BackendMode $script:BackendMode
            }
        }
    }

    Push-Location -LiteralPath $InfraDir
    try {
        switch ($Command) {
            'init' { Invoke-TfInit -ExtraArgs $RemainingArgs }
            'plan' { Invoke-TfPlan -ExtraArgs $RemainingArgs }
            'apply' { Invoke-TfApply -ExtraArgs $RemainingArgs }
            'deploy' { Invoke-TfDeploy -ExtraArgs $RemainingArgs }
            'destroy' { Invoke-TfDestroy -ExtraArgs $RemainingArgs }
            'validate' { Invoke-Native -FilePath 'terraform' -ArgumentList (@('validate') + $RemainingArgs) }
            'fmt' { Invoke-Native -FilePath 'terraform' -ArgumentList (@('fmt', '-recursive') + $RemainingArgs) }
            'output' { Invoke-Native -FilePath 'terraform' -ArgumentList (@('output') + $RemainingArgs) }
            'refresh' {
                Confirm-Initialized
                Invoke-Native -FilePath 'terraform' -ArgumentList (@('refresh') + $script:TfvarsArgs + $RemainingArgs)
            }
            'state' { Invoke-Native -FilePath 'terraform' -ArgumentList (@('state') + $RemainingArgs) }
        }
    }
    finally {
        Pop-Location
    }
}

Invoke-Main
