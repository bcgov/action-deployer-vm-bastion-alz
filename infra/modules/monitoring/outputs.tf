output "log_analytics_workspace_id" {
  description = "The resource ID of the Log Analytics workspace (created or BYO). Empty when monitoring is disabled."
  value       = local.log_analytics_workspace_id
}

output "log_analytics_workspace_workspaceId" {
  description = "The workspace (customer) GUID of the Log Analytics workspace. Null unless a workspace was created here."
  value       = local.create_log_analytics ? azurerm_log_analytics_workspace.main[0].workspace_id : null
}
