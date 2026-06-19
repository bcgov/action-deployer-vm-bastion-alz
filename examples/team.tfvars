# -----------------------------------------------------------------------------
# Example team configuration for the VM + Bastion deployer.
#
# Copy this into YOUR repo (e.g. config/my-app.tfvars) and point the composite
# action at it via the `tfvars_file` input. Override only what you need;
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
# Subnet CIDRs are required. The AzureBastionSubnet must be /26 or larger.
bastion_subnet_address_prefix = "REPLACE_ME" # e.g. 10.46.115.64/26  (must be /26 or larger)
jumpbox_subnet_address_prefix = "REPLACE_ME" # e.g. 10.46.115.128/28

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
# Pin the OS image for reproducible builds, or move to a newer LTS. Defaults to
# the latest Ubuntu 24.04 LTS server image. (Uncomment to override.)
# vm_image = {
#   publisher = "Canonical"
#   offer     = "ubuntu-24_04-lts"
#   sku       = "server"
#   version   = "latest" # or a pinned version, e.g. "24.04.202405300"
# }
# Pin the VM + Bastion to an availability zone ("1"/"2"/"3"); null = non-zonal.
# availability_zone = "1"

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
# bastion_ip_connect_enabled     = false # connect by target IP (Standard/Premium)
# bastion_shareable_link_enabled = false # shareable session links (Standard/Premium)

# --- Start/stop schedules (tfvars-only; no GitHub Action input) --------------
# Schedule timing is configurable here and ONLY here — these knobs are not
# exposed as action inputs. The values below are the defaults; uncomment to
# change. Automation times (VM start / Bastion recreate / Bastion delete) are
# UTC; the VM auto-shutdown has its own Windows time-zone field.
# vm_auto_shutdown_enabled  = true
# vm_auto_shutdown_time     = "0100"     # 24h HHmm, in vm_auto_shutdown_timezone
# vm_auto_shutdown_timezone = "UTC"      # Windows tz, e.g. "Pacific Standard Time"
# vm_auto_shutdown_notification = {        # heads-up before the VM deallocates
#   enabled        = true
#   email          = "team@example.gov.bc.ca" # and/or webhook_url
#   minutes_before = 30                        # 15-120
# }
# vm_auto_start_time_utc    = "16:00:00" # VM auto-start time (UTC)
# auto_start_week_days      = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
# bastion_create_time_utc   = "16:00:00" # Bastion recreate (UTC); needs enable_bastion_automation
# bastion_delete_time_utc   = "01:00:00" # Bastion delete   (UTC); needs enable_bastion_automation

# --- Log Analytics -----------------------------------------------------------
# Monitoring is OPTIONAL. The only consumer of the workspace is the Bastion
# connection audit trail (BastionAuditLogs). Three modes:
#   1. Create (default): leave the two settings below as-is.
#   2. Bring your own:    set existing_log_analytics_workspace_id (full resource ID).
#   3. Off:               set enable_monitoring = false (no workspace, no audit logs).
enable_monitoring            = true
log_analytics_retention_days = 30
log_analytics_sku            = "PerGB2018"
# log_analytics_daily_quota_gb = -1 # -1 = no cap; set a positive GB value to cap ingestion

# Bring-your-own Log Analytics Workspace (BYO LAW). When set, no workspace is
# created and Bastion audit logs attach to this existing one. Must be the FULL
# resource ID, not just the workspace GUID. Requires enable_monitoring = true.
# existing_log_analytics_workspace_id = "/subscriptions/REPLACE_ME/resourceGroups/REPLACE_ME/providers/Microsoft.OperationalInsights/workspaces/REPLACE_ME"
