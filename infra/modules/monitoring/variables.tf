variable "app_name" {
  description = "Name of the application"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  nullable    = false
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "Canada Central"
}

variable "log_analytics_retention_days" {
  description = "Number of days to retain data in Log Analytics Workspace"
  type        = number
  default     = 30
}

variable "log_analytics_sku" {
  description = "SKU for Log Analytics Workspace"
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_daily_quota_gb" {
  description = "Daily ingestion cap in GB for the created Log Analytics Workspace. -1 (the default) means no cap. Only applies when a workspace is created (not for BYO)."
  type        = number
  default     = -1
  nullable    = false
}

variable "enable_monitoring" {
  description = "Create/attach a Log Analytics Workspace. When false, no workspace is created and the resolved workspace ID is empty (Bastion diagnostics are skipped)."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics Workspace to use (BYO LAW). When empty, a new workspace is created."
  type        = string
  default     = ""
  nullable    = false
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}
