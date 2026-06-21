# -------------
# Root Level Terraform Configuration
# -------------
# Create the main resource group for all application resources
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

# -------------
# Modules based on Dependency
# -------------
module "network" {
  source = "./modules/network"

  common_tags                   = var.common_tags
  location                      = var.location
  resource_group_name           = azurerm_resource_group.main.name
  vnet_address_space            = var.vnet_address_space
  vnet_name                     = var.vnet_name
  vnet_resource_group_name      = var.vnet_resource_group_name
  jumpbox_subnet_name           = var.jumpbox_subnet_name
  bastion_subnet_name           = var.bastion_subnet_name
  bastion_subnet_address_prefix = var.bastion_subnet_address_prefix
  jumpbox_subnet_address_prefix = var.jumpbox_subnet_address_prefix
  depends_on                    = [azurerm_resource_group.main]
}
module "monitoring" {
  source = "./modules/monitoring"

  app_name                            = var.app_name
  common_tags                         = var.common_tags
  location                            = var.location
  enable_monitoring                   = var.enable_monitoring
  log_analytics_retention_days        = var.log_analytics_retention_days
  log_analytics_sku                   = var.log_analytics_sku
  log_analytics_daily_quota_gb        = var.log_analytics_daily_quota_gb
  existing_log_analytics_workspace_id = var.existing_log_analytics_workspace_id
  resource_group_name                 = azurerm_resource_group.main.name

  depends_on = [azurerm_resource_group.main, module.network]
}
module "bastion" {
  source  = "Azure/avm-res-network-bastionhost/azurerm"
  version = "0.9.0"
  count   = var.enable_bastion ? 1 : 0

  name                   = "${var.app_name}-bastion"
  location               = var.location
  parent_id              = azurerm_resource_group.main.id
  sku                    = var.bastion_sku
  zones                  = var.availability_zone == null ? [] : [var.availability_zone] # [] = non-zonal (original)
  tunneling_enabled      = var.bastion_tunneling_enabled
  copy_paste_enabled     = var.bastion_copy_paste_enabled
  file_copy_enabled      = var.bastion_file_copy_enabled
  ip_connect_enabled     = var.bastion_ip_connect_enabled
  shareable_link_enabled = var.bastion_shareable_link_enabled
  scale_units            = var.bastion_scale_units
  enable_telemetry       = false

  ip_configuration = {
    name                   = "configuration"
    subnet_id              = module.network.bastion_subnet_id
    create_public_ip       = true
    public_ip_address_name = "${var.app_name}-bastion-pip"
  }

  # Bastion connection audit trail -> Log Analytics (only when monitoring is on).
  # Gate solely on var.enable_monitoring (a plan-time-known bool) so the map KEYS
  # stay static at plan time. The AVM module does for_each over this map, which
  # requires keys to be known during plan. Do NOT add a check against
  # module.monitoring.log_analytics_workspace_id here: when a new workspace is
  # created in the same apply, that ID is unknown until apply, which would make
  # the whole map (and its keys) unknown and break for_each with
  # "Invalid for_each argument". The workspace_resource_id VALUE may be unknown
  # at plan time, which Terraform allows. When monitoring is on the ID is always
  # non-empty (created or BYO); when off the map is empty.
  diagnostic_settings = var.enable_monitoring ? {
    audit = {
      name                  = "${var.app_name}-bastion-audit"
      log_categories        = ["BastionAuditLogs"]
      log_groups            = []
      metric_categories     = []
      workspace_resource_id = module.monitoring.log_analytics_workspace_id
    }
  } : {}

  tags = var.common_tags
}
module "jumpbox" {
  source = "./modules/jumpbox"
  count  = var.enable_jumpbox ? 1 : 0

  app_name                     = var.app_name
  common_tags                  = var.common_tags
  location                     = var.location
  resource_group_name          = azurerm_resource_group.main.name
  vm_size                      = var.vm_size
  os_disk_type                 = var.os_disk_type
  os_disk_size_gb              = var.os_disk_size_gb
  vm_image                     = var.vm_image
  availability_zone            = var.availability_zone
  subnet_id                    = module.network.jumpbox_subnet_id
  enable_entra_login           = var.enable_entra_login
  vm_admin_login_principal_ids = var.vm_admin_login_principal_ids
  enable_bastion               = var.enable_bastion
  enable_bastion_automation    = var.enable_bastion_automation
  bastion_subnet_id            = module.network.bastion_subnet_id
  bastion_sku                  = var.bastion_sku

  # Bastion session feature toggles (kept in sync with the live Bastion above)
  bastion_tunneling_enabled      = var.bastion_tunneling_enabled
  bastion_copy_paste_enabled     = var.bastion_copy_paste_enabled
  bastion_file_copy_enabled      = var.bastion_file_copy_enabled
  bastion_ip_connect_enabled     = var.bastion_ip_connect_enabled
  bastion_shareable_link_enabled = var.bastion_shareable_link_enabled
  bastion_scale_units            = var.bastion_scale_units

  # Start/stop schedule knobs (tfvars-only)
  vm_auto_shutdown_enabled      = var.vm_auto_shutdown_enabled
  vm_auto_shutdown_time         = var.vm_auto_shutdown_time
  vm_auto_shutdown_timezone     = var.vm_auto_shutdown_timezone
  vm_auto_shutdown_notification = var.vm_auto_shutdown_notification
  vm_auto_start_time_utc        = var.vm_auto_start_time_utc
  auto_start_week_days          = var.auto_start_week_days
  bastion_create_time_utc       = var.bastion_create_time_utc
  bastion_delete_time_utc       = var.bastion_delete_time_utc

  depends_on = [module.network]
}
