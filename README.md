# action-deployer-vm-bastion-alz

A reusable **GitHub composite Action** that deploys an **Azure Bastion + Linux
jumpbox** into the BC Gov Azure Landing Zone, following ALZ policy and security
best practices (OIDC auth, no public IPs on the VM, no SSH keys, Entra ID + MFA
login).

The Terraform that builds the Bastion, jumpbox, RBAC, schedules, monitoring and
Bastion automation is **bundled in this repo** under [`infra/`](infra/). Consuming
teams do not copy any Terraform: they add the action as a step, pass a few inputs
(or a `.tfvars` file), and the deployment lands in **their** subscription /
namespace.

## How it works

```mermaid
flowchart LR
  job["Your job<br/>(environment: dev, id-token: write)"] --> co["actions/checkout<br/>(your repo + tfvars)"]
  job --> act["uses: action-deployer-vm-bastion-alz@v1<br/>(bundled infra/ at pinned ref)"]
  act --> oidc["azure/login (OIDC)"]
  act --> tf["deploy-terraform.sh<br/>init / plan / apply / destroy"]
  tf --> az["Azure: Bastion + jumpbox<br/>in your namespace"]
```

Your job checks out your repo (so the action can read your `tfvars_file`) and adds
the action as a step. The bundled `infra/` ships with the action at the exact
`@ref` you pin — no second checkout. Because the step runs inside **your job**,
the job's `environment:` and OIDC `id-token` permission apply directly, and the
environment-scoped secrets you pass as inputs resolve normally. It then runs OIDC
login and the bundled `deploy-terraform.sh` against an `azurerm` remote-state
backend you own.

## Quick start

### Initial setup (one-time, per environment)

Before the workflow can authenticate, run the BC Gov Azure Landing Zone OIDC
bootstrap **in your own repo/subscription**. It creates a user-assigned managed
identity, an **environment-scoped** OIDC federated credential, the Terraform
state storage account, and (optionally) the GitHub Environment plus its secrets
and the `STORAGE_ACCOUNT_NAME` variable:

```bash
curl -sSLO https://raw.githubusercontent.com/bcgov/quickstart-azure-containers/refs/heads/main/initial-azure-setup.sh
chmod +x initial-azure-setup.sh

# Preview first (recommended), then run for real per environment:
./initial-azure-setup.sh -g "<LICENSEPLATE>-dev-networking" -n "my-app-dev-identity" \
  -r "bcgov/my-app" -e "dev" --create-storage --create-github-secrets --dry-run
```

What it sets up for each environment:

- **OIDC federated credential** with subject `repo:<owner>/<repo>:environment:<env>` —
  i.e. it only trusts a job running in that **GitHub Environment**.
- **Environment secrets**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
  `VNET_NAME`, `VNET_RESOURCE_GROUP_NAME`.
- **Environment variable**: `STORAGE_ACCOUNT_NAME` (the Terraform state account).

> **You still add manually** (the bootstrap does not create these): `VNET_ADDRESS_SPACE`,
> `BASTION_SUBNET_ADDRESS_PREFIX`, `JUMPBOX_SUBNET_ADDRESS_PREFIX`, and
> `VM_ADMIN_LOGIN_PRINCIPAL_IDS` — all four are **required** secrets. Add them to the
> **same GitHub Environment**.

### Wire up the workflow

1. (Optional) Commit a `.tfvars` file — copy [`examples/team.tfvars`](examples/team.tfvars).
2. Add a caller workflow — copy [`examples/caller-deploy.yml`](examples/caller-deploy.yml).

Minimal caller:

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, test, prod, tools]

jobs:
  deploy:
    runs-on: ubuntu-24.04
    environment: ${{ inputs.environment }} # selects the GitHub Environment
    permissions:
      id-token: write # OIDC
      contents: read
    steps:
      - uses: actions/checkout@v6 # needed so the action can read tfvars_file
      - uses: bcgov/action-deployer-vm-bastion-alz@v1
        with:
          app_name: my-app
          app_env: ${{ inputs.environment }}
          tfvars_file: ./config/my-app.tfvars
          backend_storage_account: ${{ vars.STORAGE_ACCOUNT_NAME }}
          azure_client_id: ${{ secrets.AZURE_CLIENT_ID }}
          azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          vnet_name: ${{ secrets.VNET_NAME }}
          vnet_resource_group_name: ${{ secrets.VNET_RESOURCE_GROUP_NAME }}
          vnet_address_space: ${{ secrets.VNET_ADDRESS_SPACE }}
          bastion_subnet_address_prefix: ${{ secrets.BASTION_SUBNET_ADDRESS_PREFIX }}
          jumpbox_subnet_address_prefix: ${{ secrets.JUMPBOX_SUBNET_ADDRESS_PREFIX }}
          vm_admin_login_principal_ids: ${{ secrets.VM_ADMIN_LOGIN_PRINCIPAL_IDS }}
```

> **The job owns environment + OIDC.** Set `environment:` on the **job** (not the
> action) so environment-scoped secrets/variables resolve and OIDC trusts the
> job, and grant `permissions: id-token: write`. Secret values passed as `with:`
> inputs are still masked in logs.

> **Pin a version.** Reference the action with a tag or commit SHA
> (`...@v1`). The bundled `infra/` ships with the action at that exact ref, so the
> Terraform always matches the version you pinned.

## Configuration: tfvars + override inputs

You can configure the deployment two ways, and combine them:

- **`tfvars_file`** — a `.tfvars` file in your repo. Your job runs
  `actions/checkout`, and the action reads the file from the checked-out
  workspace at this path (relative to your repo root, e.g.
  `config/my-app.tfvars`). It is staged as the base config; the action fails with
  a clear hint if the path is missing (usually a forgotten checkout).
- **Override inputs** — discrete action inputs (`location`, `vm_size`, `bastion_sku`,
  `enable_bastion`, `enable_jumpbox`, `enable_bastion_automation`, `os_disk_size_gb`).

Precedence (highest wins):

```
override inputs (-var)  >  tfvars_file  >  secret-backed TF_VAR_* defaults
```

So an override input always wins over the same key in your tfvars file.

> **Prefer a `tfvars_file` for anything beyond the basics.** The action inputs are
> a deliberately small set of the most common knobs. The **full** set of tunables
> lives in [`infra/variables.tf`](infra/variables.tf) and is reachable **only**
> through `tfvars_file`. Some knobs — notably all **start/stop schedule** timing
> (see [Start/stop schedules](#startstop-schedules)) — have **no action input at
> all** and can only be set in tfvars. Rule of thumb: use action inputs for the
> handful of common overrides; put everything else in your `tfvars_file`.

## Network configuration

The deployer creates two subnets inside your **existing** spoke VNet (owned by the
platform team): a jumpbox subnet and `AzureBastionSubnet`. Both are always created —
`enable_bastion: false` skips the Bastion host resource but not the subnet.

| Variable | Required | Notes |
|---|---|---|
| `vnet_name` | yes (secret) | Existing spoke VNet. |
| `vnet_resource_group_name` | yes (secret) | Resource group of the VNet. |
| `vnet_address_space` | yes (secret) | CIDR of the VNet. |
| `bastion_subnet_address_prefix` | yes (secret) | CIDR for `AzureBastionSubnet`. **Must be /26 or larger.** |
| `jumpbox_subnet_address_prefix` | yes (secret) | CIDR for the jumpbox subnet. |
| `bastion_subnet_name` | no | Must stay `AzureBastionSubnet` (Azure requirement). |
| `jumpbox_subnet_name` | no | Defaults to `jumpbox-subnet`. **Set a unique value per namespace.** |

> **Validation.** Terraform rejects the deploy if `bastion_subnet_address_prefix`
> is smaller than /26 (Azure Bastion requires at least a /26), if any subnet/VNet
> value is not a valid CIDR, or if `bastion_subnet_name` is changed away from
> `AzureBastionSubnet`.

### One Bastion per VNet

Azure enforces two hard constraints that matter when multiple namespaces share a
spoke VNet:

**1. `AzureBastionSubnet` is a VNet-level singleton.**
A VNet can have only one subnet named `AzureBastionSubnet`, and Azure Bastion
requires exactly that name. This deployer always creates it. If another namespace
already owns `AzureBastionSubnet` in the target VNet, the deploy will fail — there
is no workaround short of using a separate spoke VNet.

> **In the BC Gov ALZ pattern each license plate gets its own spoke VNet**, so this
> is normally not an issue. It only arises if two license plates are deliberately
> sharing a single spoke.

**2. Jumpbox subnet names must be unique per VNet.**
The `jumpbox_subnet_name` input defaults to `jumpbox-subnet`. If another namespace
has already claimed that name in the same VNet, Terraform will attempt to modify the
existing subnet and Azure will block it. Always override this to something
namespace-specific:

```yaml
# In the caller workflow:
- uses: bcgov/action-deployer-vm-bastion-alz@v1
  with:
    jumpbox_subnet_name: myapp-jumpbox-subnet   # unique per namespace
    ...
```

or in your `tfvars_file`:

```hcl
jumpbox_subnet_name = "myapp-jumpbox-subnet"
```

## Inputs

All inputs are passed via `with:`. Values for `azure_*`, `vnet_*`, and
`vm_admin_login_principal_ids` should come from **secrets** (they are masked in
logs); `backend_storage_account` typically comes from the `STORAGE_ACCOUNT_NAME`
variable created by the bootstrap.

| Input | Required | Default | Description |
|---|---|---|---|
| `app_name` | yes | — | Application name; used for resource naming and the state key. |
| `app_env` | yes | — | Environment (e.g. `tools`, `dev`, `test`, `prod`). |
| `terraform_command` | no | `apply` | `apply`, `plan`, or `destroy`. |
| `tfvars_file` | no | `""` | Path in your checked-out repo to a `.tfvars` file. |
| `location` | no | `""` | Azure region override. |
| `resource_group_name` | no | `<app_name>-<app_env>` | Resource group name override. |
| `vm_size` | no | `""` | Jumpbox VM size override. |
| `os_disk_size_gb` | no | `""` | Jumpbox OS disk size override. |
| `bastion_sku` | no | `""` | Bastion SKU override (`Standard`/`Premium`). |
| `jumpbox_subnet_name` | no | `jumpbox-subnet` | Name of the jumpbox subnet. **Must be unique within the VNet** — override when another namespace already uses the default name. |
| `enable_bastion` | no | `""` | Deploy Bastion host (`true`/`false`). Note: `AzureBastionSubnet` is always created regardless. |
| `enable_jumpbox` | no | `""` | Deploy jumpbox (`true`/`false`). |
| `enable_bastion_automation` | no | `""` | Bastion delete/recreate automation (`true`/`false`). |
| `enable_monitoring` | no | `""` | Create/attach a Log Analytics Workspace + Bastion audit logs. Set `false` to skip. |
| `existing_log_analytics_workspace_id` | no | `""` | BYO Log Analytics Workspace resource ID. When set, no workspace is created. |
| `backend_storage_account` | yes | — | Storage account for Terraform state. Pass `${{ vars.STORAGE_ACCOUNT_NAME }}`. |
| `backend_resource_group` | no | `vnet_resource_group_name` | Resource group of the state storage account. |
| `backend_container_name` | no | `tfstate` | Blob container for state. |
| `backend_state_key` | no | `<app_name>/<app_env>/terraform.tfstate` | State blob key. |
| `azure_client_id` | yes | — | OIDC app (client) ID. Pass from a secret. |
| `azure_tenant_id` | yes | — | Azure AD tenant ID. Pass from a secret. |
| `azure_subscription_id` | yes | — | Target subscription ID. Pass from a secret. |
| `vnet_name` | yes | — | Existing spoke VNet name. Pass from a secret. |
| `vnet_resource_group_name` | yes | — | Resource group of the existing VNet. Pass from a secret. |
| `vnet_address_space` | yes | — | Address space of the VNet (e.g. `10.46.115.0/24`). Pass from a secret. |
| `bastion_subnet_address_prefix` | yes | — | CIDR for `AzureBastionSubnet` (e.g. `10.46.115.64/26`). Must be /26 or larger. Pass from a secret. |
| `jumpbox_subnet_address_prefix` | yes | — | CIDR for the jumpbox subnet (e.g. `10.46.115.128/28`). Pass from a secret. |
| `vm_admin_login_principal_ids` | yes | — | Comma-separated Entra object IDs (users/groups) for jumpbox login. Pass from a secret. See [Jumpbox access](#jumpbox-access-vm-admin-login). |

> **Network details are secrets by design.** `vnet_name`, `vnet_resource_group_name`,
> `vnet_address_space`, `bastion_subnet_address_prefix`, and `jumpbox_subnet_address_prefix`
> are required and should be passed from secrets, never as plain literals or committed
> tfvars. This keeps VNet names and IP ranges out of workflow logs, PRs, and committed
> config, and puts the responsibility on the calling team to supply (and safeguard) their
> own network information.

### Secrets created by the bootstrap

The [initial setup](#initial-setup-one-time-per-environment) script creates these
as **environment** secrets/variables; map them into the action inputs as shown in
the caller example:

| GitHub item | Kind | Created by bootstrap | Maps to input |
|---|---|---|---|
| `AZURE_CLIENT_ID` | secret | yes | `azure_client_id` |
| `AZURE_TENANT_ID` | secret | yes | `azure_tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | secret | yes | `azure_subscription_id` |
| `VNET_NAME` | secret | yes | `vnet_name` |
| `VNET_RESOURCE_GROUP_NAME` | secret | yes | `vnet_resource_group_name` |
| `STORAGE_ACCOUNT_NAME` | variable | yes | `backend_storage_account` |
| `VNET_ADDRESS_SPACE` | secret | **no — add manually** | `vnet_address_space` |
| `BASTION_SUBNET_ADDRESS_PREFIX` | secret | **no — add manually** | `bastion_subnet_address_prefix` |
| `JUMPBOX_SUBNET_ADDRESS_PREFIX` | secret | **no — add manually** | `jumpbox_subnet_address_prefix` |
| `VM_ADMIN_LOGIN_PRINCIPAL_IDS` | secret | **no — add manually** | `vm_admin_login_principal_ids` |

## Jumpbox access (VM Admin Login)

Entra-SSH access to the jumpbox is gated by Azure RBAC: the deployer assigns the
**Virtual Machine Administrator Login** role to every principal you list in the
`VM_ADMIN_LOGIN_PRINCIPAL_IDS` secret. This is **required** — with an empty list
the role is never assigned and **nobody can log in**, which makes the entire
Bastion + jumpbox path unusable. The deployer fails fast if the secret is empty
or contains a value that is not an object ID.

Format of the `VM_ADMIN_LOGIN_PRINCIPAL_IDS` secret:

- A **comma-separated** string — no brackets, no quotes, e.g.
  `11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222`.
- Each value is an Entra **object ID (GUID)** for a **user** or a **group**.
  A group is recommended so you manage who has access in Entra, not in CI.
- Use object IDs, **not** UPNs, emails, or display names — those are rejected.

Find object IDs with the Azure CLI:

```bash
# A user, by sign-in name
az ad user show --id alice@example.gov.bc.ca --query id -o tsv

# A group, by display name
az ad group show --group "My Team Jumpbox Admins" --query id -o tsv
```

Examples of the secret value:

| Grant access to | `VM_ADMIN_LOGIN_PRINCIPAL_IDS` |
|---|---|
| one group (recommended) | `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa` |
| two users | `1111...-1111,2222...-2222` |
| a group + a break-glass user | `aaaaaaaa-...,99999999-...` |

## Operations

Set `terraform_command` to choose the operation:

- `apply` — create/update (auto-approved in CI).
- `plan` — preview changes only.
- `destroy` — tear down the namespace (auto-approved in CI).

## What gets deployed

| Component | Purpose |
|---|---|
| Azure Bastion (Standard) | Native client tunneling for AAD-authenticated SSH |
| Ubuntu jumpbox VM | Minimal Linux host, no public IP, Entra SSH login |
| RBAC assignments | VM Admin / User Login for configured Entra principals |
| Auto-shutdown / auto-start | DevTest schedule + Automation runbook |
| Log Analytics workspace | **Optional** — created by default for the Bastion audit trail; BYO or disable (see below) |
| Update Manager assessment | Patch compliance visibility |

See [`infra/`](infra/) for the layout. The Bastion host and the jumpbox VM are
provisioned via [Azure Verified Modules](https://aka.ms/avm) —
`avm-res-network-bastionhost` (called from the root) and
`avm-res-compute-virtualmachine` (called inside the `jumpbox` module). The local
modules `network`, `jumpbox`, and `monitoring` wrap the subnets/NSGs, the
Automation runbooks, and Log Analytics. See
[`infra/variables.tf`](infra/variables.tf) for the full set of tunable variables.

## VM image and placement

Two more tfvars-only knobs control the jumpbox image and its zone placement:

| Knob | Effect | Default |
|---|---|---|
| `vm_image` | Source image (`publisher`/`offer`/`sku`/`version`). Pin `version` for reproducible builds instead of `latest`. | latest Ubuntu 24.04 LTS server |
| `availability_zone` | Pin the VM **and** Bastion to a zone (`"1"`/`"2"`/`"3"`) | `null` (non-zonal) |

```hcl
vm_image = {
  publisher = "Canonical"
  offer     = "ubuntu-24_04-lts"
  sku       = "server"
  version   = "24.04.202405300" # pin instead of "latest"
}
availability_zone = "1"
```

> **Changing either forces a replacement** — a new image version recreates the VM,
> and a zone change recreates the VM (and the Bastion). Plan a maintenance window.

## Start/stop schedules

To save cost the jumpbox is **deallocated overnight** and **restarted on a
schedule**, and (optionally) Azure Bastion is **deleted after hours and
recreated** the next working day. All of this timing is configurable — but
**only via `tfvars_file`**. There are no action inputs for schedules.

| Schedule | What it does | Default | Knob(s) |
|---|---|---|---|
| VM auto-shutdown | Deallocates the jumpbox daily | 01:00 daily (UTC) | `vm_auto_shutdown_enabled`, `vm_auto_shutdown_time`, `vm_auto_shutdown_timezone`, `vm_auto_shutdown_notification` |
| VM auto-start | Restarts the jumpbox on working days | 16:00 UTC, Mon–Fri | `vm_auto_start_time_utc`, `auto_start_week_days` |
| Bastion recreate\* | Recreates Bastion on working days | 16:00 UTC, Mon–Fri | `bastion_create_time_utc`, `auto_start_week_days` |
| Bastion delete\* | Deletes Bastion after hours | 01:00 UTC daily | `bastion_delete_time_utc` |

\* Bastion delete/recreate only runs when `enable_bastion_automation = true`.

- **VM auto-shutdown** uses Azure's DevTest schedule: `vm_auto_shutdown_time` is
  24-hour `HHmm` (no colon) interpreted in `vm_auto_shutdown_timezone` — a
  **Windows** time-zone ID such as `Pacific Standard Time`. Set
  `vm_auto_shutdown_enabled = false` to keep the VM running.
- **The automation schedules** (VM start, Bastion recreate/delete) are **UTC**;
  give the time as `HH:MM:SS`. `auto_start_week_days` is shared by the VM-start
  and Bastion-recreate schedules (full English weekday names).
- **Pre-shutdown notification** (`vm_auto_shutdown_notification`) is off by
  default. Set `enabled = true` with an `email` (semicolon-separated for multiple)
  and/or a `webhook_url`, plus `minutes_before` (15–120), for a heads-up before
  the VM deallocates.

Example — start later in the day, run Mon–Sat, and shut the VM down at 6 PM local:

```hcl
vm_auto_start_time_utc    = "14:00:00"
bastion_create_time_utc   = "14:00:00"
bastion_delete_time_utc   = "02:00:00"
auto_start_week_days      = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
vm_auto_shutdown_time     = "1800"                  # 6:00 PM…
vm_auto_shutdown_timezone = "Pacific Standard Time" # …local time
```

## Bastion session options

Azure Bastion's session features are tfvars-only knobs (no action input). They
apply to **both** the live Bastion and the one the automation runbook recreates,
so the two always stay in sync:

| Knob | Effect | Default |
|---|---|---|
| `bastion_tunneling_enabled` | Native client tunneling (required for the SOCKS proxy) | `true` |
| `bastion_copy_paste_enabled` | Clipboard copy/paste in sessions | `true` |
| `bastion_file_copy_enabled` | File copy in sessions | `false` |
| `bastion_ip_connect_enabled` | Connect to a target by IP | `false` |
| `bastion_shareable_link_enabled` | Shareable session links | `false` |
| `bastion_scale_units` | Bastion scale units (instances) | `2` |

Tunneling, file copy, IP connect, and shareable links require the **Standard**
(or Premium) SKU — the default `bastion_sku`. Leave `bastion_tunneling_enabled`
on: the [bastion-proxy](bastion-consumer-scripts/bastion-proxy.md) workflow
depends on it.

## Monitoring (optional Log Analytics)

The **only** consumer of the Log Analytics Workspace is the Bastion connection
audit trail (the `BastionAuditLogs` diagnostic category — who connected through
Bastion, to which VM, when). The jumpbox itself ships no monitoring agent. So the
workspace exists purely for that audit trail, and is **not required** for Bastion
or the jumpbox to function. There are three modes:

| Mode | Set | Result |
|---|---|---|
| **Create (default)** | nothing | A workspace `<app_name>-law` is created and receives Bastion audit logs. |
| **Bring your own** | `existing_log_analytics_workspace_id` | No workspace is created; audit logs go to the workspace you pass. |
| **Off** | `enable_monitoring = false` | No workspace and no Bastion diagnostic setting are created. |

When a workspace is **created** (the default), three tfvars tune it:
`log_analytics_retention_days` (default `30`), `log_analytics_sku` (default
`PerGB2018`), and `log_analytics_daily_quota_gb` — a daily ingestion cap in GB,
default `-1` (no cap). These don't apply to a BYO workspace.

BYO example (resource ID, **not** just the workspace GUID):

```hcl
existing_log_analytics_workspace_id = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"
```

or as an action input:

```yaml
with:
  existing_log_analytics_workspace_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
```

> **Resource ID, not GUID.** Azure diagnostic settings need the full workspace
> resource ID. Terraform validates the format and fails early if only a bare GUID
> is supplied.
>
> **BYO needs RBAC, not a key.** The deploying OIDC identity must be able to write
> a diagnostic setting targeting the workspace. If the BYO workspace is in another
> resource group or subscription, grant that identity **Monitoring Contributor**
> (or **Log Analytics Contributor**) on the workspace scope. No workspace shared
> key is needed.

## Repository structure

```text
.
├── action.yml                       # Composite action (entry point)
├── .github/
│   ├── workflows/
│   │   ├── validate.yml               # PR gate: terraform fmt/validate + tflint
│   │   ├── release.yml                # Tag + GitHub Release on push to main
│   │   └── dependabot-auto-merge.yml  # Auto-approve + merge Dependabot PRs
│   ├── scripts/
│   │   ├── run-deploy.sh              # Action entry point (stage tfvars, overrides, run)
│   │   └── setup-repo-protection.sh   # One-time gh-api repo hardening (admins)
│   └── dependabot.yml
├── infra/                       # Bundled Terraform (Bastion + jumpbox + ...)
│   ├── main.tf                  # Root: RG + Bastion (AVM) + network/monitoring/jumpbox modules
│   ├── deploy-terraform.sh      # init/plan/apply/destroy orchestration
│   └── modules/                 # network, jumpbox (VM via AVM), monitoring
├── bastion-consumer-scripts/    # Hand to teams to reach the jumpbox via Bastion
│   ├── bastion-proxy.sh         # SOCKS5 proxy tunnel (macOS/Linux/Git Bash)
│   ├── bastion-proxy.ps1        # SOCKS5 proxy tunnel (Windows PowerShell)
│   └── bastion-proxy.md         # Consumer-facing usage guide
├── examples/
│   ├── caller-deploy.yml        # Copy into your repo's workflows
│   ├── team.tfvars              # Copy + edit for your config (GitHub Actions)
│   └── local.tfvars             # Copy to infra/terraform.tfvars for local use
└── README.md
```

## Admin setup (this repo)

Repository maintainers run a one-time script to enable the merge automation. It
uses the GitHub CLI (`gh`) and requires admin rights on the repo:

```bash
gh auth login
./.github/scripts/setup-repo-protection.sh
```

It enables repo auto-merge (squash-only, delete branch on merge) and applies
branch protection on `main` (1 required approval, linear history, conversation
resolution, no force-push/deletion). Combined with
[`dependabot-auto-merge.yml`](.github/workflows/dependabot-auto-merge.yml), patch
and minor Dependabot PRs are auto-approved and merged once checks pass; majors
wait for a human. Override defaults with env vars, e.g.:

```bash
REVIEW_COUNT=2 REQUIRED_CHECKS="terraform-validate,lint" \
  ./.github/scripts/setup-repo-protection.sh
```

## Local deployment

The same `infra/deploy-terraform.sh` script that the composite action runs in CI works directly on a developer workstation — useful for ad-hoc deploys, one-off troubleshooting, or testing before wiring up CI. It uses Azure CLI authentication instead of OIDC.

### Prerequisites

Install the following tools before running locally:

| Tool | Minimum version | Install guide |
|---|---|---|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.65+ | See platform instructions below |
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.12+ | See platform instructions below |
| [Git](https://git-scm.com/downloads) | 2.x | Pre-installed on macOS/Linux |
| Bash | 4.x+ | Windows: use **Git Bash** (from Git for Windows) or **WSL2** |

Verify after installing:

```bash
az version         # must show "azure-cli": "2.65.0" or higher
terraform version  # must show Terraform v1.12.x or higher
bash --version     # must be 4.x+ (macOS ships 3.2 — install via Homebrew)
```

#### macOS (Homebrew)

```bash
brew update
brew install azure-cli
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
brew install bash          # macOS ships Bash 3.2; the deploy script requires 4+
```

#### Windows (winget)

```powershell
winget install Microsoft.AzureCLI
winget install HashiCorp.Terraform
# Git for Windows (includes Git Bash):
winget install Git.Git
```

Run all deploy commands in **Git Bash**, not PowerShell or cmd.exe — the deploy script is a Bash script.

#### Linux (apt / manual)

```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Terraform — download the binary for your architecture
TERRAFORM_VERSION=1.12.0
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o tf.zip
unzip tf.zip && sudo mv terraform /usr/local/bin/ && rm tf.zip
```

### Required Azure permissions

Your user account needs the following RBAC roles on the target subscription:

| Role | Scope | Purpose |
|---|---|---|
| **Contributor** | Target subscription | Create resource group, VM, Bastion, Automation Account, etc. |
| **User Access Administrator** | Target subscription | Assign RBAC roles (VM Admin Login) to Entra principals |
| **Network Contributor** | VNet resource group | Create subnets in the existing spoke VNet |

> **Owner** on the subscription covers all three. For least-privilege, scope **Network Contributor** to just the VNet resource group rather than the whole subscription.

### Step-by-step local deployment

**1. Clone this repo at a specific version**

```bash
git clone https://github.com/bcgov/action-deployer-vm-bastion-alz.git
cd action-deployer-vm-bastion-alz
git checkout v1          # pin to a release tag: v1, v1.2.3, or a commit SHA
```

**2. Log in to Azure**

```bash
# Log in (optionally pass --tenant <tenant-id> to target a specific Entra tenant)
az login

# Set the target subscription
az account set --subscription "<your-subscription-id>"

# Verify
az account show --query "[name, id]" -o tsv
```

**3. Create a local tfvars file**

```bash
cp examples/local.tfvars infra/terraform.tfvars
# Edit infra/terraform.tfvars — replace every REPLACE_ME placeholder
```

`infra/terraform.tfvars` is git-ignored, so real subscription IDs, VNet names, and principal IDs will never be committed. See the [local vs GHA differences table](#local-vs-gha-differences) for what goes in each field.

**4. Set backend environment variables**

```bash
export BACKEND_RESOURCE_GROUP="<resource-group-of-storage-account>"
export BACKEND_STORAGE_ACCOUNT="<storage-account-name>"    # from STORAGE_ACCOUNT_NAME in GHA
export BACKEND_STATE_KEY="my-app/tools/terraform.tfstate"  # must match the key used in CI
# BACKEND_CONTAINER_NAME defaults to "tfstate" — override if your container differs
```

Use the same storage account created by `initial-azure-setup.sh`. Sharing the backend with CI means local and CI deployments operate on the same state file.

**5. Plan and apply**

```bash
./infra/deploy-terraform.sh plan     # preview changes (no Azure writes)
./infra/deploy-terraform.sh apply    # deploy (prompts for confirmation — no auto-approve locally)
./infra/deploy-terraform.sh destroy  # tear down (also prompts for confirmation)
```

### Local vs GHA differences

| Concern | GitHub Actions | Local |
|---|---|---|
| **Authentication** | OIDC federated credential | Azure CLI (`az login`) |
| `use_oidc` | `true` (default) | `false` — set in `infra/terraform.tfvars` |
| `client_id` | Set from OIDC app registration | `""` — not needed for CLI auth |
| **Sensitive variables** | GitHub Environment secrets → `TF_VAR_*` env vars | All in `infra/terraform.tfvars` (git-ignored) |
| `vm_admin_login_principal_ids` | Comma-separated string from secret; converted by `run-deploy.sh` | HCL list in tfvars: `["guid1", "guid2"]` |
| `common_tags` | JSON map injected as `TF_VAR_common_tags` env var | HCL map literal in tfvars |
| `resource_group_name` | Defaults to `<app_name>-<app_env>` | Must be set explicitly in tfvars |
| **Auto-approve** | Yes (`CI=true`) | No — script prompts `yes` before apply/destroy |
| **State backend** | Set via action inputs | Set via `BACKEND_*` env vars |

### Local tfvars fields

The [`examples/local.tfvars`](examples/local.tfvars) template includes every required variable with a `REPLACE_ME` placeholder. Key fields that differ from [`examples/team.tfvars`](examples/team.tfvars):

| Variable | Value for local | Notes |
|---|---|---|
| `use_oidc` | `false` | Use CLI auth locally; `true` (default) in GHA |
| `client_id` | `""` | Not needed for CLI auth |
| `subscription_id` | Your subscription GUID | Same as `AZURE_SUBSCRIPTION_ID` secret in GHA |
| `tenant_id` | Your Entra tenant GUID | Same as `AZURE_TENANT_ID` secret in GHA |
| `resource_group_name` | `"my-app-tools"` | GHA computes `<app_name>-<app_env>`; explicit locally |
| `common_tags` | HCL map `{ environment = "..." }` | GHA injects as JSON env var |
| `vnet_name` | Your VNet name | Same value as `VNET_NAME` GitHub secret |
| `vnet_resource_group_name` | VNet resource group | Same as `VNET_RESOURCE_GROUP_NAME` secret |
| `vnet_address_space` | VNet CIDR | Same as `VNET_ADDRESS_SPACE` secret |
| `bastion_subnet_address_prefix` | `/26` or larger CIDR | Same as `BASTION_SUBNET_ADDRESS_PREFIX` secret |
| `jumpbox_subnet_address_prefix` | Any valid CIDR | Same as `JUMPBOX_SUBNET_ADDRESS_PREFIX` secret |
| `vm_admin_login_principal_ids` | `["guid1", "guid2"]` | HCL list, not comma-separated string |

> **`vm_admin_login_principal_ids` format difference**: The GHA action's `run-deploy.sh` converts a comma-separated string to a Terraform `list(string)`. Locally, skip that conversion and write the list directly in the tfvars file:
>
> ```hcl
> vm_admin_login_principal_ids = ["11111111-1111-1111-1111-111111111111"]
> ```

### Useful local commands

```bash
# Show Terraform outputs after a successful apply
./infra/deploy-terraform.sh output

# Target a specific module (e.g. re-apply Bastion only)
./infra/deploy-terraform.sh apply -target=module.bastion

# Validate syntax and format — no Azure auth or backend needed
./infra/deploy-terraform.sh validate
./infra/deploy-terraform.sh fmt

# List all resources tracked in state
./infra/deploy-terraform.sh state list

# Refresh state from Azure (after out-of-band changes)
./infra/deploy-terraform.sh refresh

# Remove a resource from state without destroying it in Azure
./infra/deploy-terraform.sh state rm <resource.address>
```

**Connect to the jumpbox after deployment:**

Use the bundled script to open a SOCKS5 proxy tunnel through Azure Bastion. It installs the Bastion CLI extension on first use, starts the jumpbox if auto-shutdown has deallocated it, and waits for the proxy to come up. Log in first with `az login`.

Derive the names from Terraform outputs and your current Azure context (run from
the repo root):

```bash
# Resource names from Terraform state; subscription/tenant from your az login
RG="<app_name>-<app_env>"   # e.g. my-app-tools
BASTION_NAME="$(cd infra && terraform output -raw bastion_resource_id | sed 's|.*/||')"
VM_NAME="$(cd infra && terraform output -raw jumpbox_vm_id            | sed 's|.*/||')"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
```

**macOS / Linux / Windows (Git Bash)** — [`bastion-consumer-scripts/bastion-proxy.sh`](bastion-consumer-scripts/bastion-proxy.sh):

```bash
./bastion-consumer-scripts/bastion-proxy.sh \
  -g "$RG" \
  -b "$BASTION_NAME" \
  -v "$VM_NAME" \
  -s "$SUBSCRIPTION_ID" \
  -t "$TENANT_ID" \
  -p 8228
```

Once the tunnel is ready the script prints the proxy address; point your browser or CLI at `socks5h://127.0.0.1:8228` to reach private endpoints. Traffic routed through the SOCKS5 proxy is resolved and forwarded by the jumpbox, giving access to private PaaS endpoints without a VPN. Pass the starting port with `-p` (here `8228`); if it's already in use the script picks the next free one and prints it.
