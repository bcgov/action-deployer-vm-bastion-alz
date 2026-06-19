# -----------------------------------------------------------------------------
# Jumpbox Module Outputs
# -----------------------------------------------------------------------------

output "vm_id" {
  description = "ID of the jumpbox virtual machine"
  value       = module.vm.resource_id
}

output "vm_name" {
  description = "Name of the jumpbox virtual machine"
  value       = module.vm.name
}

output "private_ip_address" {
  description = "Private IP address of the jumpbox VM"
  value       = module.vm.virtual_machine_azurerm.private_ip_address
}

output "admin_username" {
  description = "Local admin username required by the VM resource. Interactive access uses Entra ID SSH login."
  value       = module.vm.admin_username
}

output "principal_id" {
  description = "Principal ID of the VM's managed identity"
  value       = module.vm.system_assigned_mi_principal_id
}

output "auto_shutdown_time" {
  description = "Configured VM auto-shutdown schedule"
  value       = var.vm_auto_shutdown_enabled ? "${var.vm_auto_shutdown_time} ${var.vm_auto_shutdown_timezone} (daily)" : "disabled"
}

output "auto_start_schedule" {
  description = "Configured VM auto-start schedule"
  value       = "${var.vm_auto_start_time_utc} UTC (${join(", ", var.auto_start_week_days)})"
}

output "automation_account_id" {
  description = "ID of the Azure Automation Account for VM auto-start"
  value       = azurerm_automation_account.jumpbox.id
}

output "automation_account_name" {
  description = "Name of the Azure Automation Account used for jumpbox and optional Bastion automation"
  value       = azurerm_automation_account.jumpbox.name
}

output "bastion_automation_enabled" {
  description = "Whether Bastion delete/recreate automation runbooks are enabled"
  value       = var.enable_bastion && var.enable_bastion_automation
}

output "bastion_create_runbook_name" {
  description = "Runbook name that recreates Bastion on demand"
  value       = var.enable_bastion && var.enable_bastion_automation ? azurerm_automation_runbook.create_bastion[0].name : null
}

output "bastion_delete_runbook_name" {
  description = "Runbook name that deletes Bastion after hours"
  value       = var.enable_bastion && var.enable_bastion_automation ? azurerm_automation_runbook.delete_bastion[0].name : null
}

output "entra_login_enabled" {
  description = "Whether Microsoft Entra ID SSH login is enabled on the jumpbox"
  value       = var.enable_entra_login
}
