variable "app_name" {
  description = "Name of the application"
  type        = string
  nullable    = false
}
variable "common_tags" {
  description = "Common tags to apply to all resources (the action injects app_env/environment/repo_name/managed_by)."
  type        = map(string)
}
variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "Canada Central"
}
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  nullable    = false
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
  sensitive   = true
}

variable "use_oidc" {
  description = "Use OIDC for authentication"
  type        = bool
  default     = true
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the virtual network, it is created by platform team"

  validation {
    condition     = can(cidrhost(var.vnet_address_space, 0))
    error_message = "vnet_address_space must be a valid CIDR block (e.g. 10.46.115.0/24)."
  }
}

variable "vnet_name" {
  description = "Name of the existing virtual network"
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group name where the virtual network exists"
  type        = string
}

variable "jumpbox_subnet_name" {
  description = "Name of the jumpbox VM subnet to create in the existing VNet."
  type        = string
  default     = "jumpbox-subnet"
  nullable    = false
}

variable "bastion_subnet_name" {
  description = "Name of the Azure Bastion subnet. Azure requires this to be exactly 'AzureBastionSubnet'."
  type        = string
  default     = "AzureBastionSubnet"
  nullable    = false

  validation {
    condition     = var.bastion_subnet_name == "AzureBastionSubnet"
    error_message = "bastion_subnet_name must be 'AzureBastionSubnet' (Azure Bastion requirement)."
  }
}

variable "bastion_subnet_address_prefix" {
  description = "CIDR for the AzureBastionSubnet. Must be /26 or larger (e.g. 10.46.115.64/26)."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrhost(var.bastion_subnet_address_prefix, 0))
    error_message = "bastion_subnet_address_prefix must be a valid CIDR (e.g. 10.46.115.64/26)."
  }

  validation {
    condition     = try(tonumber(split("/", var.bastion_subnet_address_prefix)[1]) <= 26, false)
    error_message = "AzureBastionSubnet must be /26 or larger (prefix length <= 26). Azure Bastion requires at least a /26 subnet."
  }
}

variable "jumpbox_subnet_address_prefix" {
  description = "CIDR for the jumpbox subnet (e.g. 10.46.115.128/28)."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrhost(var.jumpbox_subnet_address_prefix, 0))
    error_message = "jumpbox_subnet_address_prefix must be a valid CIDR (e.g. 10.46.115.128/28)."
  }
}

variable "client_id" {
  description = "Azure client ID for the service principal or OIDC application. Leave empty when using Azure CLI authentication (use_oidc = false) — the CLI token is used instead."
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_bastion" {
  description = "Enable deployment of the Azure Bastion host"
  type        = bool
  default     = true
}

variable "enable_bastion_automation" {
  description = "Enable Azure Automation runbooks that delete Bastion after hours and recreate it on weekdays or on demand"
  type        = bool
  default     = true
}

variable "bastion_sku" {
  description = "SKU for Azure Bastion. Standard or Premium is required for native tunneling."
  type        = string
  default     = "Standard"
}

# Bastion session feature toggles. Applied to BOTH the live Bastion and the one
# the automation runbook recreates, so the two configurations stay in sync.
variable "bastion_tunneling_enabled" {
  description = "Enable native client tunneling on Azure Bastion (required for the SOCKS proxy / bastion-proxy script). Requires the Standard or Premium SKU."
  type        = bool
  default     = true
}

variable "bastion_copy_paste_enabled" {
  description = "Enable clipboard copy/paste in Azure Bastion sessions."
  type        = bool
  default     = true
}

variable "bastion_file_copy_enabled" {
  description = "Enable file copy in Azure Bastion sessions. Requires the Standard or Premium SKU."
  type        = bool
  default     = false
}

variable "bastion_ip_connect_enabled" {
  description = "Enable connecting to a target by IP address in Azure Bastion. Requires the Standard or Premium SKU."
  type        = bool
  default     = false
}

variable "bastion_shareable_link_enabled" {
  description = "Enable shareable session links in Azure Bastion. Requires the Standard or Premium SKU."
  type        = bool
  default     = false
}

variable "bastion_scale_units" {
  description = "Number of scale units (instances) for Azure Bastion. Standard/Premium only; ignored for the Basic SKU."
  type        = number
  default     = 2
}

variable "enable_jumpbox" {
  description = "Enable deployment of the Azure Jumpbox VM"
  type        = bool
  default     = true
}

variable "enable_entra_login" {
  description = "Enable Microsoft Entra ID (AAD) SSH login on the Linux jumpbox VM"
  type        = bool
  default     = true
}

variable "vm_admin_login_principal_ids" {
  description = "Microsoft Entra object IDs (users or groups) to grant the Virtual Machine Administrator Login role on the jumpbox. At least one is required for anyone to Entra-SSH in; an empty list grants no access. Values must be object IDs (GUIDs), not UPNs or display names."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "vm_size" {
  description = "Size of the Linux jumpbox VM. Increase this to scale the single jumpbox vertically."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "os_disk_type" {
  description = "Storage account type for the jumpbox OS disk. Standard SSD avoids the Standard HDD retirement path."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "os_disk_size_gb" {
  description = "Size of the jumpbox OS disk in GB."
  type        = number
  default     = 64
}

### -----------------------------------------------------------------------------
### Log Analytics Variables
### -----------------------------------------------------------------------------
variable "enable_monitoring" {
  description = "Create a Log Analytics Workspace (or attach a BYO one) and enable the Bastion connection audit trail. Set to false if you do not need Bastion audit logs — a Log Analytics Workspace is not required for Bastion/jumpbox to function."
  type        = bool
  default     = true
  nullable    = false
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

variable "existing_log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics Workspace to use (bring-your-own LAW). When set, no workspace is created and Bastion audit logs attach to this workspace. When empty, a new workspace named '<app_name>-law' is created. Requires enable_monitoring = true (the default). Must be the full Azure resource ID, not just the workspace GUID."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.existing_log_analytics_workspace_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft.operationalinsights/workspaces/[^/]+$", var.existing_log_analytics_workspace_id))
    error_message = "existing_log_analytics_workspace_id must be the full Azure resource ID of a Log Analytics Workspace (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>), not just the workspace GUID."
  }
}

### -----------------------------------------------------------------------------
### Start/stop schedule knobs (tfvars-only; not exposed as GitHub Action inputs)
### -----------------------------------------------------------------------------
### Defaults preserve the original behaviour: the jumpbox VM deallocates daily at
### 01:00 and is restarted at 16:00 UTC on weekdays. When Bastion automation is on,
### Bastion is deleted daily at 01:00 UTC and recreated at 16:00 UTC on weekdays.

variable "vm_auto_shutdown_enabled" {
  description = "Enable the daily auto-shutdown (deallocate) schedule on the jumpbox VM."
  type        = bool
  default     = true
  nullable    = false
}

variable "vm_auto_shutdown_time" {
  description = "Daily VM auto-shutdown time as 24h HHmm with no colon (DevTest schedule format), interpreted in vm_auto_shutdown_timezone. Example: '0100' = 1:00 AM."
  type        = string
  default     = "0100"
  nullable    = false

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.vm_auto_shutdown_time))
    error_message = "vm_auto_shutdown_time must be 24h HHmm with no colon, e.g. '0100' or '1830'."
  }
}

variable "vm_auto_shutdown_timezone" {
  description = "Windows time zone ID for the VM auto-shutdown schedule, e.g. 'UTC' or 'Pacific Standard Time'."
  type        = string
  default     = "UTC"
  nullable    = false
}

variable "vm_auto_start_time_utc" {
  description = "Time (UTC, HH:MM:SS) the jumpbox VM is auto-started on the scheduled days. Example: '16:00:00'."
  type        = string
  default     = "16:00:00"
  nullable    = false

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$", var.vm_auto_start_time_utc))
    error_message = "vm_auto_start_time_utc must be UTC HH:MM:SS, e.g. '16:00:00'."
  }
}

variable "auto_start_week_days" {
  description = "Days of the week the VM auto-start and the Bastion auto-recreate schedules run."
  type        = list(string)
  default     = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  nullable    = false

  validation {
    condition     = length(var.auto_start_week_days) > 0 && alltrue([for d in var.auto_start_week_days : contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], d)])
    error_message = "auto_start_week_days must be a non-empty list of full English weekday names (e.g. \"Monday\")."
  }
}

variable "bastion_create_time_utc" {
  description = "Time (UTC, HH:MM:SS) the Bastion host is recreated on the scheduled days. Only used when enable_bastion_automation = true."
  type        = string
  default     = "16:00:00"
  nullable    = false

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$", var.bastion_create_time_utc))
    error_message = "bastion_create_time_utc must be UTC HH:MM:SS, e.g. '16:00:00'."
  }
}

variable "bastion_delete_time_utc" {
  description = "Time (UTC, HH:MM:SS) the Bastion host is deleted each day (after hours). Only used when enable_bastion_automation = true."
  type        = string
  default     = "01:00:00"
  nullable    = false

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$", var.bastion_delete_time_utc))
    error_message = "bastion_delete_time_utc must be UTC HH:MM:SS, e.g. '01:00:00'."
  }
}
