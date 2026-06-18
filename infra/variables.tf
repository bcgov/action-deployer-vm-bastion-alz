
variable "app_env" {
  description = "Application environment (dev, test, prod)"
  type        = string
  nullable    = false
}

variable "app_name" {
  description = "Name of the application"
  type        = string
  nullable    = false
}
variable "common_tags" {
  description = "Common tags to apply to all resources"
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
  description = "Explicit CIDR for the AzureBastionSubnet. Must be /26 or larger (e.g. /26, /25, /24). Leave empty to derive from vnet_address_space (assumes a /24 spoke)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.bastion_subnet_address_prefix == "" || can(cidrhost(var.bastion_subnet_address_prefix, 0))
    error_message = "bastion_subnet_address_prefix must be a valid CIDR (e.g. 10.46.115.64/26) or empty to auto-derive."
  }

  validation {
    condition     = var.bastion_subnet_address_prefix == "" || try(tonumber(split("/", var.bastion_subnet_address_prefix)[1]) <= 26, false)
    error_message = "AzureBastionSubnet must be /26 or larger (prefix length <= 26). Azure Bastion requires at least a /26 subnet."
  }
}

variable "jumpbox_subnet_address_prefix" {
  description = "Explicit CIDR for the jumpbox subnet. Leave empty to derive from vnet_address_space (assumes a /24 spoke)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.jumpbox_subnet_address_prefix == "" || can(cidrhost(var.jumpbox_subnet_address_prefix, 0))
    error_message = "jumpbox_subnet_address_prefix must be a valid CIDR (e.g. 10.46.115.128/28) or empty to auto-derive."
  }
}

variable "client_id" {
  description = "Azure client ID for the service principal"
  type        = string
  sensitive   = true
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

variable "bastion_tunneling_enabled" {
  description = "Enable native client tunneling for Azure Bastion."
  type        = bool
  default     = true
}

variable "bastion_copy_paste_enabled" {
  description = "Enable copy and paste in Azure Bastion sessions."
  type        = bool
  default     = true
}

variable "bastion_file_copy_enabled" {
  description = "Enable file copy in Azure Bastion sessions."
  type        = bool
  default     = false
}

variable "bastion_ip_connect_enabled" {
  description = "Enable Azure Bastion IP Connect."
  type        = bool
  default     = false
}

variable "bastion_shareable_link_enabled" {
  description = "Enable Azure Bastion shareable links."
  type        = bool
  default     = false
}

variable "bastion_scale_units" {
  description = "Scale units to configure on the Azure Bastion host."
  type        = number
  default     = 2
}

variable "bastion_public_ip_sku" {
  description = "SKU for the Azure Bastion public IP."
  type        = string
  default     = "Standard"
}

variable "bastion_public_ip_sku_tier" {
  description = "SKU tier for the Azure Bastion public IP."
  type        = string
  default     = "Regional"
}

variable "bastion_public_ip_allocation_method" {
  description = "Allocation method for the Azure Bastion public IP."
  type        = string
  default     = "Static"
}

variable "bastion_public_ip_version" {
  description = "IP version for the Azure Bastion public IP."
  type        = string
  default     = "IPv4"
}

variable "bastion_public_ip_idle_timeout_in_minutes" {
  description = "Idle timeout in minutes for the Azure Bastion public IP."
  type        = number
  default     = 4
}

variable "bastion_public_ip_ddos_protection_mode" {
  description = "DDoS protection mode for the Azure Bastion public IP."
  type        = string
  default     = "VirtualNetworkInherited"
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
