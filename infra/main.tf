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
  existing_log_analytics_workspace_id = var.existing_log_analytics_workspace_id
  resource_group_name                 = azurerm_resource_group.main.name

  depends_on = [azurerm_resource_group.main, module.network]
}
module "bastion" {
  source  = "Azure/avm-res-network-bastionhost/azurerm"
  version = "0.9.0"
  count   = var.enable_bastion ? 1 : 0

  name               = "${var.app_name}-bastion"
  location           = var.location
  parent_id          = azurerm_resource_group.main.id
  sku                = var.bastion_sku
  zones              = [] # match the original non-zonal Bastion; safe in non-AZ regions
  tunneling_enabled  = true
  copy_paste_enabled = true
  enable_telemetry   = false

  ip_configuration = {
    name                   = "configuration"
    subnet_id              = module.network.bastion_subnet_id
    create_public_ip       = true
    public_ip_address_name = "${var.app_name}-bastion-pip"
  }

  # Bastion connection audit trail -> Log Analytics (only when monitoring is on).
  diagnostic_settings = var.enable_monitoring && module.monitoring.log_analytics_workspace_id != "" ? {
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
  subnet_id                    = module.network.jumpbox_subnet_id
  enable_entra_login           = var.enable_entra_login
  vm_admin_login_principal_ids = var.vm_admin_login_principal_ids
  enable_bastion               = var.enable_bastion
  enable_bastion_automation    = var.enable_bastion_automation
  bastion_subnet_id            = module.network.bastion_subnet_id
  bastion_sku                  = var.bastion_sku
  depends_on                   = [module.network]
}
