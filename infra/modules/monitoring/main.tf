locals {
  # Monitoring is optional. When enabled, either create a Log Analytics
  # Workspace or use a caller-supplied (BYO) one. When disabled, no workspace is
  # created and the resolved ID is empty so downstream diagnostics are skipped.
  create_log_analytics       = var.enable_monitoring && var.existing_log_analytics_workspace_id == ""
  log_analytics_workspace_id = var.enable_monitoring ? (local.create_log_analytics ? azurerm_log_analytics_workspace.main[0].id : var.existing_log_analytics_workspace_id) : ""
}

# Log Analytics Workspace (created only when monitoring is enabled and an
# existing workspace is not provided).
resource "azurerm_log_analytics_workspace" "main" {
  count               = local.create_log_analytics ? 1 : 0
  name                = "${var.app_name}-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_days
  daily_quota_gb      = var.log_analytics_daily_quota_gb

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}
