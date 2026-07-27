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
# Git are installed automatically if missing (winget, then Chocolatey, then a
# direct download), the same way bastion-consumer-scripts/bastion-proxy.ps1
# already installs the Azure CLI. Machine-wide installs can prompt for
# elevation -- run from an elevated ("Run as Administrator") PowerShell to
# avoid interruptions.
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
    # non-breaking addition (e.g. a remote-exec mode) has a home.
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

$InfraDir = $PSScriptRoot
$TfvarsFile = $null # resolved in Invoke-Main by Resolve-TfvarsPath

$BackendResourceGroup = if ($env:BACKEND_RESOURCE_GROUP) { $env:BACKEND_RESOURCE_GROUP } else { '' }
$BackendStorageAccount = if ($env:BACKEND_STORAGE_ACCOUNT) { $env:BACKEND_STORAGE_ACCOUNT } else { '' }
$BackendContainerName = if ($env:BACKEND_CONTAINER_NAME) { $env:BACKEND_CONTAINER_NAME } else { 'tfstate' }
$BackendStateKey = if ($env:BACKEND_STATE_KEY) { $env:BACKEND_STATE_KEY } else { '' }

$script:UseTfvars = $false
$script:TfvarsArgs = @()

function Test-CiMode { return $env:CI -eq 'true' }

function Write-DeployLog {
    param([string]$Msg)
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "$timestamp [deploy] $Msg"
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

function Update-ProcessPathFromEnvironment {
    $pathParts = @(
        ($env:Path -split ';'),
        ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';'),
        ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $env:Path = $pathParts -join ';'
}

function Install-AzureCliIfMissing {
    if (Test-CommandAvailable 'az') {
        Write-DeployLog "Azure CLI ready: $(Get-ExecutableCommandPath (Get-Command az))"
        return
    }

    Write-DeployLog 'Azure CLI (az) is not installed. Attempting installation...'

    $wingetCommand = Get-InstallerCommand -Names @('winget.exe', 'winget')
    $chocoCommand = Get-InstallerCommand -Names @('choco.exe', 'choco')

    if ($wingetCommand) {
        $wingetPath = Get-ExecutableCommandPath $wingetCommand
        Write-DeployLog 'Installing Azure CLI with WinGet...'
        & $wingetPath install --exact --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: WinGet returned exit code $LASTEXITCODE while installing Azure CLI." }
    }
    elseif ($chocoCommand) {
        $chocoPath = Get-ExecutableCommandPath $chocoCommand
        Write-DeployLog 'Installing Azure CLI with Chocolatey...'
        & $chocoPath install azure-cli -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: Chocolatey returned exit code $LASTEXITCODE while installing Azure CLI." }
    }
    else {
        $installerPath = Join-Path $env:TEMP 'AzureCLI.msi'
        Write-DeployLog 'Installing Azure CLI with the Microsoft MSI installer...'
        try {
            Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -OutFile $installerPath
            $installerProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $installerPath, '/passive', '/norestart') -Wait -PassThru
            if ($installerProcess.ExitCode -notin @(0, 3010)) {
                Write-DeployLog "WARN: Azure CLI MSI installer returned exit code $($installerProcess.ExitCode)."
            }
        }
        finally {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Update-ProcessPathFromEnvironment
    if (-not (Test-CommandAvailable 'az')) {
        Write-DeployLog 'ERROR: Azure CLI could not be resolved after installation. Re-run in a fresh shell or install manually from https://learn.microsoft.com/cli/azure/install-azure-cli'
        exit 1
    }
    Write-DeployLog "Azure CLI ready: $(Get-ExecutableCommandPath (Get-Command az))"
}

function Install-GitIfMissing {
    if (Test-CommandAvailable 'git') {
        Write-DeployLog "Git ready: $(Get-ExecutableCommandPath (Get-Command git))"
        return
    }

    Write-DeployLog 'Git is not installed. Attempting installation...'

    $wingetCommand = Get-InstallerCommand -Names @('winget.exe', 'winget')
    $chocoCommand = Get-InstallerCommand -Names @('choco.exe', 'choco')

    if ($wingetCommand) {
        $wingetPath = Get-ExecutableCommandPath $wingetCommand
        Write-DeployLog 'Installing Git with WinGet...'
        & $wingetPath install --exact --id Git.Git --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: WinGet returned exit code $LASTEXITCODE while installing Git." }
    }
    elseif ($chocoCommand) {
        $chocoPath = Get-ExecutableCommandPath $chocoCommand
        Write-DeployLog 'Installing Git with Chocolatey...'
        & $chocoPath install git -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: Chocolatey returned exit code $LASTEXITCODE while installing Git." }
    }
    else {
        $installerPath = Join-Path $env:TEMP 'GitInstaller.exe'
        Write-DeployLog 'Installing Git with the official Git for Windows installer...'
        try {
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -TimeoutSec 15
            $asset = $release.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1
            if (-not $asset) { throw 'Could not find a 64-bit Git for Windows installer asset.' }
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath
            $installerProcess = Start-Process -FilePath $installerPath -ArgumentList @('/VERYSILENT', '/NORESTART') -Wait -PassThru
            if ($installerProcess.ExitCode -ne 0) {
                Write-DeployLog "WARN: Git installer returned exit code $($installerProcess.ExitCode)."
            }
        }
        finally {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    Update-ProcessPathFromEnvironment
    if (-not (Test-CommandAvailable 'git')) {
        Write-DeployLog 'ERROR: Git could not be resolved after installation. Re-run in a fresh shell or install manually from https://git-scm.com/downloads'
        exit 1
    }
    Write-DeployLog "Git ready: $(Get-ExecutableCommandPath (Get-Command git))"
}

function Get-TerraformArch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    return 'amd64'
}

function Get-LatestTerraformVersion {
    param([string]$FallbackVersion = '1.12.0')
    try {
        $response = Invoke-RestMethod -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' -TimeoutSec 10
        if ($response.current_version) { return $response.current_version }
    }
    catch {
        Write-DeployLog "WARN: Could not resolve latest Terraform version ($($_.Exception.Message)); falling back to $FallbackVersion"
    }
    return $FallbackVersion
}

function Install-TerraformIfMissing {
    if (Test-CommandAvailable 'terraform') {
        Write-DeployLog "Terraform ready: $(Get-ExecutableCommandPath (Get-Command terraform))"
        return
    }

    Write-DeployLog 'Terraform is not installed. Attempting installation...'

    $wingetCommand = Get-InstallerCommand -Names @('winget.exe', 'winget')
    $chocoCommand = Get-InstallerCommand -Names @('choco.exe', 'choco')

    if ($wingetCommand) {
        $wingetPath = Get-ExecutableCommandPath $wingetCommand
        Write-DeployLog 'Installing Terraform with WinGet...'
        & $wingetPath install --exact --id HashiCorp.Terraform --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: WinGet returned exit code $LASTEXITCODE while installing Terraform." }
    }
    elseif ($chocoCommand) {
        $chocoPath = Get-ExecutableCommandPath $chocoCommand
        Write-DeployLog 'Installing Terraform with Chocolatey...'
        & $chocoPath install terraform -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "WARN: Chocolatey returned exit code $LASTEXITCODE while installing Terraform." }
    }
    else {
        $version = Get-LatestTerraformVersion
        $arch = Get-TerraformArch
        $installDir = Join-Path $env:LocalAppData 'Programs\Terraform'
        $zipPath = Join-Path $env:TEMP "terraform_${version}_windows_${arch}.zip"
        $downloadUrl = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_windows_${arch}.zip"

        Write-DeployLog "Installing Terraform $version ($arch) from HashiCorp releases..."
        try {
            New-Item -ItemType Directory -Force -Path $installDir | Out-Null
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
            Expand-Archive -Path $zipPath -DestinationPath $installDir -Force
        }
        finally {
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $userPathParts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($userPathParts -notcontains $installDir) {
            [Environment]::SetEnvironmentVariable('Path', (($userPathParts + $installDir) -join ';'), 'User')
        }
    }

    Update-ProcessPathFromEnvironment
    if (-not (Test-CommandAvailable 'terraform')) {
        Write-DeployLog 'ERROR: Terraform could not be resolved after installation. Re-run in a fresh shell or install manually from https://developer.hashicorp.com/terraform/install'
        exit 1
    }
    Write-DeployLog "Terraform ready: $(Get-ExecutableCommandPath (Get-Command terraform))"
}

function Test-InfraCheckoutPresent {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path (Join-Path $Path 'main.tf') -PathType Leaf) -and (Test-Path (Join-Path $Path 'backend.tf') -PathType Leaf)
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

    Write-DeployLog 'Standalone script detected (no infra/ checkout next to deploy-terraform.ps1); self-bootstrapping one with Git...'
    Install-GitIfMissing

    $repoUrl = 'https://github.com/bcgov/action-deployer-vm-bastion-alz.git'
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'bcgov\action-deployer-vm-bastion-alz'
    $repoDir = Join-Path $cacheRoot $Ref
    $isNewCheckout = -not (Test-Path (Join-Path $repoDir '.git') -PathType Container)

    if ($isNewCheckout) {
        Write-DeployLog "Cloning $repoUrl (ref: $Ref) into $repoDir..."
        New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
    }
    else {
        Write-DeployLog "Updating cached checkout ($repoDir, ref: $Ref)..."
    }

    Push-Location $repoDir
    try {
        if ($isNewCheckout) {
            Invoke-Native -FilePath 'git' -ArgumentList @('init', '-q')
            Invoke-Native -FilePath 'git' -ArgumentList @('remote', 'add', 'origin', $repoUrl)
        }
        Invoke-Native -FilePath 'git' -ArgumentList @('fetch', '--depth', '1', 'origin', $Ref)
        Invoke-Native -FilePath 'git' -ArgumentList @('checkout', '--force', 'FETCH_HEAD')
    }
    finally {
        Pop-Location
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
    $null = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (Test-CiMode) {
            Write-DeployLog 'CI mode: assuming OIDC/service-principal authentication'
        }
        else {
            Write-DeployLog "Not logged in to Azure; running 'az login'..."
            az login
            if ($LASTEXITCODE -ne 0) { exit 1 }
        }
    }
}

function Get-TfvarsSubscriptionId {
    if (-not (Test-Path $TfvarsFile)) { return '' }
    $match = Select-String -Path $TfvarsFile -Pattern '^\s*subscription_id\s*=\s*"([^"]*)"' | Select-Object -First 1
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
            $candidate = Join-Path (Get-Location) $candidate
        }
        if (-not (Test-Path $candidate -PathType Leaf)) {
            Write-DeployLog "ERROR: -TfvarsPath '$Explicit' was not found. Create one first: copy examples/local.tfvars from the repo (or download it directly: https://raw.githubusercontent.com/bcgov/action-deployer-vm-bastion-alz/main/examples/local.tfvars), fill in every REPLACE_ME value, then re-run with -TfvarsPath pointing at your copy."
            exit 1
        }
        return (Resolve-Path -Path $candidate).ProviderPath
    }

    return (Join-Path $InfraDir 'terraform.tfvars')
}

function Set-AzureAuth {
    $sub = if ($env:TF_VAR_subscription_id) { $env:TF_VAR_subscription_id } else { '' }
    if (-not $sub) { $sub = Get-TfvarsSubscriptionId }
    if ($sub) {
        az account set --subscription $sub
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }

    if ($sub) {
        $env:ARM_SUBSCRIPTION_ID = $sub
    }
    else {
        $env:ARM_SUBSCRIPTION_ID = (az account show --query id -o tsv)
    }
    $env:ARM_TENANT_ID = if ($env:TF_VAR_tenant_id) { $env:TF_VAR_tenant_id } else { '' }

    $useOidc = ($env:ARM_USE_OIDC -eq 'true') -or ($env:TF_VAR_use_oidc -eq 'true')
    if ($useOidc) {
        $env:ARM_USE_OIDC = 'true'
        $env:ARM_CLIENT_ID = if ($env:TF_VAR_client_id) { $env:TF_VAR_client_id } elseif ($env:ARM_CLIENT_ID) { $env:ARM_CLIENT_ID } else { '' }
        Write-DeployLog 'Using OIDC authentication'
    }
    else {
        $env:ARM_USE_CLI = 'true'
        Write-DeployLog 'Using Azure CLI authentication'
    }
}

function Set-VariablesSource {
    if (Test-Path $TfvarsFile) {
        $script:UseTfvars = $true
        $script:TfvarsArgs = @("-var-file=$TfvarsFile")
        Write-DeployLog 'Using terraform.tfvars'
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
        [ValidateSet('azurerm', 'local')][string]$BackendMode = 'azurerm'
    )

    Push-Location $InfraDir
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
    Push-Location $InfraDir
    try {
        $isInitialized = (Test-Path '.terraform' -PathType Container) -and (Test-Path '.terraform.lock.hcl' -PathType Leaf)
        if (-not $isInitialized) { Invoke-TfInit }
    }
    finally {
        Pop-Location
    }
}

function Invoke-TfPlan {
    param([string[]]$ExtraArgs = @())

    Confirm-Initialized
    Push-Location $InfraDir
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
    Push-Location $InfraDir
    try {
        $applyArgs = @('apply') + $script:TfvarsArgs
        if (Test-CiMode) { $applyArgs += '-auto-approve' }
        $applyArgs += $ExtraArgs
        Invoke-Native -FilePath 'terraform' -ArgumentList $applyArgs
        Write-DeployLog 'Apply complete; outputs:'
        terraform output
    }
    finally {
        Pop-Location
    }
}

function Resolve-BackendMode {
    # deploy only: azurerm when all required BACKEND_* env vars are set (same
    # remote state CI uses), otherwise fall back to local Terraform state so
    # `deploy` never hard-fails just because no shared backend was configured.
    $hasRemoteConfig = [bool]($BackendResourceGroup -and $BackendStorageAccount -and $BackendStateKey)
    if ($hasRemoteConfig) { return 'azurerm' }

    Write-DeployLog 'WARN: BACKEND_* environment variables are not fully set -- falling back to LOCAL Terraform state (infra/terraform.tfstate).'
    Write-DeployLog 'WARN: Local state lives only on this machine and is NOT shared. Do not use this mode for team/shared deployments -- set BACKEND_RESOURCE_GROUP, BACKEND_STORAGE_ACCOUNT, and BACKEND_STATE_KEY to use the shared azurerm backend instead.'
    return 'local'
}

function Set-LocalBackendOverride {
    param(
        [Parameter(Mandatory)][string]$InfraPath,
        [Parameter(Mandatory)][ValidateSet('azurerm', 'local')][string]$BackendMode
    )

    $overridePath = Join-Path $InfraPath 'local_backend_override.tf'
    if ($BackendMode -eq 'local') {
        Set-Content -Path $overridePath -Encoding utf8 -Value @'
# Generated by deploy-terraform.ps1 (no BACKEND_* env vars set) -- overrides
# backend.tf's `backend "azurerm" {}` with local state for this machine only.
# Safe to delete; git-ignored; regenerated automatically on the next `deploy`.
terraform {
  backend "local" {}
}
'@
    }
    else {
        Remove-Item -Path $overridePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-DeployBackendModeMarkerPath {
    return (Join-Path $InfraDir '.deploy-backend-mode')
}

function Test-BackendModeChanged {
    param([Parameter(Mandatory)][string]$CurrentMode)

    $markerPath = Get-DeployBackendModeMarkerPath
    if (-not (Test-Path $markerPath -PathType Leaf)) { return $false }
    $previousMode = Get-Content -Path $markerPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $previousMode) { return $false }
    return ($previousMode.Trim() -ne '') -and ($previousMode.Trim() -ne $CurrentMode)
}

function Set-DeployBackendModeMarker {
    param([Parameter(Mandatory)][string]$BackendMode)
    Set-Content -Path (Get-DeployBackendModeMarkerPath) -Value $BackendMode -Encoding utf8 -NoNewline
}

function Invoke-TfDeploy {
    param([string[]]$ExtraArgs = @())

    $backendMode = Resolve-BackendMode
    Set-LocalBackendOverride -InfraPath $InfraDir -BackendMode $backendMode

    $initExtraArgs = @()
    if (Test-BackendModeChanged -CurrentMode $backendMode) {
        Write-DeployLog 'Backend mode changed since the last deploy in this infra directory; re-initializing with -reconfigure.'
        $initExtraArgs += '-reconfigure'
    }

    Push-Location $InfraDir
    try {
        Invoke-TfInit -ExtraArgs $initExtraArgs -BackendMode $backendMode
        Set-DeployBackendModeMarker -BackendMode $backendMode

        $applyArgs = @('apply') + $script:TfvarsArgs + $ExtraArgs
        Invoke-Native -FilePath 'terraform' -ArgumentList $applyArgs
        Write-DeployLog 'Deploy complete; outputs:'
        terraform output
    }
    finally {
        Pop-Location
    }
}

function Invoke-TfDestroy {
    param([string[]]$ExtraArgs = @())

    Confirm-Initialized
    Push-Location $InfraDir
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
        $script:InfraDir = Resolve-InfraDir -Ref $Ref
    }
    $script:TfvarsFile = Resolve-TfvarsPath -Explicit $TfvarsPath

    Install-TerraformIfMissing

    switch ($Command) {
        { $_ -in @('fmt', 'validate') } { } # no Azure auth needed
        default {
            Install-AzureCliIfMissing
            Confirm-AzureLogin
            Set-AzureAuth
            Set-VariablesSource
        }
    }

    Push-Location $InfraDir
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
