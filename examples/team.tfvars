# -----------------------------------------------------------------------------
# Example team configuration for the VM + Bastion deployer.
#
# Copy this into YOUR repo (e.g. config/my-app.tfvars) and point the reusable
# workflow at it via the `tfvars_file` input. Override only what you need;
# everything here except app_name/app_env has a sensible default.
#
# DO NOT put secrets here. subscription_id, client_id, tenant_id and the VNet
# details are supplied by the workflow from GitHub secrets (OIDC).
# -----------------------------------------------------------------------------

# --- Identity / namespace ----------------------------------------------------
app_name = "my-app"
app_env  = "tools"

# location is "Canada Central" by default; resource_group_name defaults to
# "<app_name>-<app_env>". Uncomment to override.
# location            = "Canada Central"
# resource_group_name = "my-app-tools"

# --- Network / subnets -------------------------------------------------------
# Two subnets are created inside your existing spoke VNet. Subnet names default
# as shown; the Bastion subnet name MUST stay "AzureBastionSubnet".
# bastion_subnet_name = "AzureBastionSubnet"
# jumpbox_subnet_name = "jumpbox-subnet"
#
# Explicit subnet CIDRs. Leave unset to auto-derive from the VNet (assumes a
# /24 spoke). The AzureBastionSubnet MUST be /26 or larger (/26, /25, /24...).
# Set both explicitly if your VNet is not a /24.
# bastion_subnet_address_prefix = "10.46.115.64/26"
# jumpbox_subnet_address_prefix = "10.46.115.128/28"

# --- Tags --------------------------------------------------------------------
# The workflow sets a default common_tags map. Uncomment to fully control tags.
# common_tags = {
#   environment = "tools"
#   app_env     = "tools"
#   project     = "my-app"
#   managed_by  = "Terraform"
# }

# --- Jumpbox VM --------------------------------------------------------------
vm_size         = "Standard_B2als_v2"
os_disk_type    = "StandardSSD_LRS"
os_disk_size_gb = 64

# --- Toggles -----------------------------------------------------------------
enable_jumpbox            = true
enable_bastion            = true
enable_entra_login        = true
enable_bastion_automation = true

# --- Bastion -----------------------------------------------------------------
bastion_sku                = "Standard"
bastion_tunneling_enabled  = true
bastion_copy_paste_enabled = true
bastion_file_copy_enabled  = false
bastion_scale_units        = 2

# --- Log Analytics -----------------------------------------------------------
# Monitoring is OPTIONAL. The only consumer of the workspace is the Bastion
# connection audit trail (BastionAuditLogs). Three modes:
#   1. Create (default): leave the two settings below as-is.
#   2. Bring your own:    set existing_log_analytics_workspace_id (full resource ID).
#   3. Off:               set enable_monitoring = false (no workspace, no audit logs).
enable_monitoring            = true
log_analytics_retention_days = 30
log_analytics_sku            = "PerGB2018"

# Bring-your-own Log Analytics Workspace (BYO LAW). When set, no workspace is
# created and Bastion audit logs attach to this existing one. Must be the FULL
# resource ID, not just the workspace GUID. Requires enable_monitoring = true.
# existing_log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/central-logging/providers/Microsoft.OperationalInsights/workspaces/central-law"
