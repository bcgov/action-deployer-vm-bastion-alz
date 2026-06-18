# =============================================================================
# Local deployment configuration for action-deployer-vm-bastion-alz
# =============================================================================
# Copy this file to infra/terraform.tfvars and replace every REPLACE_ME value.
#
#   cp examples/local.tfvars infra/terraform.tfvars
#
# infra/terraform.tfvars is git-ignored — real values will not be committed.
#
# In GitHub Actions the values below are injected as TF_VAR_* environment
# variables from GitHub Secrets. Locally they live in this tfvars file instead.
#
# See README.md → "Local deployment" for the full step-by-step walkthrough.
# =============================================================================

# =============================================================================
# Authentication
# =============================================================================
# Use Azure CLI auth for local runs (az login handles identity). In GitHub
# Actions use_oidc = true and client_id is supplied via the OIDC federated
# credential. Leave both values below as-is for CLI auth.
use_oidc  = false
client_id = ""

# Your target Azure subscription and the BC Gov tenant.
subscription_id = "REPLACE_ME" # e.g. 00000000-0000-0000-0000-000000000000
tenant_id       = "REPLACE_ME" # e.g. 00000000-0000-0000-0000-000000000000

# =============================================================================
# Identity / namespace
# =============================================================================
app_name            = "my-app"       # Prefix for all Azure resource names
app_env             = "tools"        # Environment label: tools | dev | test | prod
resource_group_name = "my-app-tools" # Must be explicit locally; GHA defaults to "<app_name>-<app_env>"

# Tags applied to all resources. GHA injects these automatically from the
# action inputs; set them explicitly here.
common_tags = {
  environment = "tools"
  app_env     = "tools"
  project     = "my-app"
  managed_by  = "Terraform"
}

# Azure region. Default is "Canada Central".
# location = "Canada Central"

# =============================================================================
# Network
# =============================================================================
# The deployer creates two new subnets inside an EXISTING spoke VNet owned
# by the BC Gov platform team. Provide the same network details that you
# would store as GitHub Secrets (VNET_NAME, VNET_RESOURCE_GROUP_NAME, etc.)
# in the GHA workflow.
vnet_name                = "REPLACE_ME" # Existing spoke VNet name
vnet_resource_group_name = "REPLACE_ME" # Resource group that owns the VNet

# Full address space of the VNet (not just a subnet CIDR).
vnet_address_space = "REPLACE_ME" # e.g. 10.46.115.0/24

# Subnet CIDRs — must be within the VNet space and not already allocated.
# AzureBastionSubnet must be /26 or larger (Azure hard requirement).
bastion_subnet_address_prefix = "REPLACE_ME" # e.g. 10.46.115.64/26  (must be /26 or larger)
jumpbox_subnet_address_prefix = "REPLACE_ME" # e.g. 10.46.115.128/28

# Optional: override the jumpbox subnet name when another namespace already
# uses the default "jumpbox-subnet" in this VNet.
# jumpbox_subnet_name = "jumpbox-subnet"

# =============================================================================
# Jumpbox access — who can Entra-SSH into the VM through Bastion
# =============================================================================
# In GHA this comes from the VM_ADMIN_LOGIN_PRINCIPAL_IDS secret as a
# comma-separated string (converted by run-deploy.sh). Locally it is a
# Terraform list(string) of Entra object IDs (GUIDs), NOT UPNs or emails.
#
# Find a user's object ID:  az ad user show --id you@example.gov.bc.ca --query id -o tsv
# Find a group's object ID: az ad group show --group "My Team" --query id -o tsv
vm_admin_login_principal_ids = [
  "REPLACE_ME", # e.g. 11111111-1111-1111-1111-111111111111
]

# =============================================================================
# Jumpbox VM
# =============================================================================
vm_size         = "Standard_B2als_v2"
os_disk_type    = "StandardSSD_LRS"
os_disk_size_gb = 64

# =============================================================================
# Feature toggles
# =============================================================================
enable_jumpbox            = true
enable_bastion            = true
enable_entra_login        = true
enable_bastion_automation = true

# =============================================================================
# Bastion configuration
# =============================================================================
bastion_sku                = "Standard"
bastion_tunneling_enabled  = true
bastion_copy_paste_enabled = true
bastion_file_copy_enabled  = false
bastion_scale_units        = 2

# =============================================================================
# Monitoring (optional Log Analytics Workspace)
# =============================================================================
# The workspace is only used for Bastion connection audit logs (BastionAuditLogs).
# Three modes:
#   1. Create (default): leave the settings below unchanged.
#   2. Bring your own:   set existing_log_analytics_workspace_id (full resource ID).
#   3. Off:              set enable_monitoring = false.
enable_monitoring            = true
log_analytics_retention_days = 30
log_analytics_sku            = "PerGB2018"

# Bring-your-own Log Analytics Workspace. Must be the full Azure resource ID.
# existing_log_analytics_workspace_id = "/subscriptions/REPLACE_ME/resourceGroups/REPLACE_ME/providers/Microsoft.OperationalInsights/workspaces/REPLACE_ME"
