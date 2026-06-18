# -------------
# Root Level Terraform Configuration
# -------------
locals {
  # Ensure every resource carries the environment tag even when a caller
  # supplies its own common_tags map without app_env. The action already
  # injects app_env into common_tags, so this merge is idempotent in CI and
  # also gives the otherwise-unused app_env variable a concrete purpose.
  common_tags = merge(var.common_tags, { app_env = var.app_env })
}

# Create the main resource group for all application resources
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
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

  common_tags                   = local.common_tags
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
  common_tags                         = local.common_tags
  location                            = var.location
  enable_monitoring                   = var.enable_monitoring
  log_analytics_retention_days        = var.log_analytics_retention_days
  log_analytics_sku                   = var.log_analytics_sku
  existing_log_analytics_workspace_id = var.existing_log_analytics_workspace_id
  resource_group_name                 = azurerm_resource_group.main.name

  depends_on = [azurerm_resource_group.main, module.network]
}
module "bastion" {
  source = "./modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  app_name                          = var.app_name
  common_tags                       = local.common_tags
  location                          = var.location
  resource_group_name               = azurerm_resource_group.main.name
  log_analytics_workspace_id        = module.monitoring.log_analytics_workspace_id
  bastion_subnet_id                 = module.network.bastion_subnet_id
  bastion_sku                       = var.bastion_sku
  tunneling_enabled                 = var.bastion_tunneling_enabled
  copy_paste_enabled                = var.bastion_copy_paste_enabled
  file_copy_enabled                 = var.bastion_file_copy_enabled
  ip_connect_enabled                = var.bastion_ip_connect_enabled
  shareable_link_enabled            = var.bastion_shareable_link_enabled
  scale_units                       = var.bastion_scale_units
  public_ip_sku                     = var.bastion_public_ip_sku
  public_ip_sku_tier                = var.bastion_public_ip_sku_tier
  public_ip_allocation_method       = var.bastion_public_ip_allocation_method
  public_ip_version                 = var.bastion_public_ip_version
  public_ip_idle_timeout_in_minutes = var.bastion_public_ip_idle_timeout_in_minutes
  public_ip_ddos_protection_mode    = var.bastion_public_ip_ddos_protection_mode

}
module "jumpbox" {
  source = "./modules/jumpbox"
  count  = var.enable_jumpbox ? 1 : 0

  app_name                                  = var.app_name
  common_tags                               = local.common_tags
  location                                  = var.location
  resource_group_name                       = azurerm_resource_group.main.name
  vm_size                                   = var.vm_size
  os_disk_type                              = var.os_disk_type
  os_disk_size_gb                           = var.os_disk_size_gb
  subnet_id                                 = module.network.jumpbox_subnet_id
  enable_entra_login                        = var.enable_entra_login
  vm_admin_login_principal_ids              = var.vm_admin_login_principal_ids
  enable_bastion                            = var.enable_bastion
  enable_bastion_automation                 = var.enable_bastion_automation
  bastion_subnet_id                         = module.network.bastion_subnet_id
  bastion_sku                               = var.bastion_sku
  bastion_tunneling_enabled                 = var.bastion_tunneling_enabled
  bastion_copy_paste_enabled                = var.bastion_copy_paste_enabled
  bastion_file_copy_enabled                 = var.bastion_file_copy_enabled
  bastion_ip_connect_enabled                = var.bastion_ip_connect_enabled
  bastion_shareable_link_enabled            = var.bastion_shareable_link_enabled
  bastion_scale_units                       = var.bastion_scale_units
  bastion_public_ip_sku                     = var.bastion_public_ip_sku
  bastion_public_ip_sku_tier                = var.bastion_public_ip_sku_tier
  bastion_public_ip_allocation_method       = var.bastion_public_ip_allocation_method
  bastion_public_ip_version                 = var.bastion_public_ip_version
  bastion_public_ip_idle_timeout_in_minutes = var.bastion_public_ip_idle_timeout_in_minutes
  bastion_public_ip_ddos_protection_mode    = var.bastion_public_ip_ddos_protection_mode
  depends_on                                = [module.network]
}

