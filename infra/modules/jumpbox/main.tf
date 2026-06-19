# -----------------------------------------------------------------------------
# Azure Linux VM (Jumpbox/Tunnel) Module
# -----------------------------------------------------------------------------
# Creates a minimal Linux VM used only as an Azure Bastion SOCKS tunnel endpoint.
# Authentication is through Microsoft Entra ID SSH login. AzureRM still requires
# a bootstrap SSH public key for VM creation, but no private key is written locally.
# -----------------------------------------------------------------------------

data "azurerm_subscription" "current" {}

# Jumpbox VM (+ NIC, system identity, SSH key, auto-shutdown, Entra-SSH extension,
# and VM-scoped role assignments) via the Azure Verified Module. The module
# generates a throwaway SSH key (password auth disabled); developer access is
# Entra-only. ALZ guest-patching/assessment knobs are passed through.
module "vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "0.21.0"

  name                = "${var.app_name}-jumpbox"
  resource_group_name = var.resource_group_name
  location            = var.location
  zone                = null # non-zonal, matching the original VM
  os_type             = "Linux"
  sku_size            = var.vm_size
  enable_telemetry    = false

  # The AVM defaults encryption-at-host ON, which requires the
  # Microsoft.Compute/EncryptionAtHost subscription feature to be registered or the
  # VM create hard-fails. Keep it off to match the original VM and stay portable
  # across BC Gov subscriptions that haven't registered the feature.
  encryption_at_host_enabled = false

  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interfaces = {
    primary = {
      name = "${var.app_name}-jumpbox-nic"
      ip_configurations = {
        internal = {
          name                          = "internal"
          private_ip_subnet_resource_id = var.subnet_id
        }
      }
    }
  }

  managed_identities = {
    system_assigned = true
  }

  # ALZ guest patching + Update Manager assessment.
  provision_vm_agent    = true
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"

  # Entra ID SSH login.
  extensions = var.enable_entra_login ? {
    aad_ssh_login = {
      name                       = "AADSSHLoginForLinux"
      publisher                  = "Microsoft.Azure.ActiveDirectory"
      type                       = "AADSSHLoginForLinux"
      type_handler_version       = "1.0"
      auto_upgrade_minor_version = true
    }
  } : {}

  # Auto-shutdown at 01:00 UTC (6 PM Pacific with the repo's +7 offset).
  shutdown_schedules = {
    daily = {
      daily_recurrence_time = "0100"
      timezone              = "UTC"
      enabled               = true
      notification_settings = { enabled = false }
    }
  }

  # VM-scoped RBAC: Entra "VM Administrator Login" for each principal, plus
  # "VM Contributor" for the Automation managed identity that starts the VM.
  role_assignments = merge(
    { for id in var.vm_admin_login_principal_ids : "admin-login-${id}" => {
      role_definition_id_or_name = "Virtual Machine Administrator Login"
      principal_id               = id
    } },
    {
      automation-vm-contributor = {
        role_definition_id_or_name = "Virtual Machine Contributor"
        principal_id               = azurerm_automation_account.jumpbox.identity[0].principal_id
      }
    }
  )

  tags = var.common_tags
}

resource "azurerm_automation_account" "jumpbox" {
  name                = "${var.app_name}-jumpbox-automation"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azapi_resource" "python310" {
  type      = "Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23"
  parent_id = azurerm_automation_account.jumpbox.id
  name      = "python310-runtime"
  location  = var.location

  body = {
    properties = {
      description = "Python 3.10 runtime for runbooks"
      runtime = {
        language = "Python"
        version  = "3.10"
      }
    }
  }

  # runtimeEnvironments API (2024-10-23) accepts at most 3 tags; drop app_env which
  # duplicates the environment tag value in this context.
  tags = { for k, v in var.common_tags : k => v if k != "app_env" }
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "start_vm" {
  name                     = "Start-JumpboxVM"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name

  content = templatefile("${path.module}/scripts/start_vm.py", {
    subscription_id     = data.azurerm_subscription.current.subscription_id
    resource_group_name = var.resource_group_name
    app_name            = var.app_name
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.weekday_start.name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "create_bastion" {
  count                    = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                     = "Create-BastionHost"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name


  content = templatefile("${path.module}/scripts/create_bastion.py", {
    subscription_id                           = data.azurerm_subscription.current.subscription_id
    resource_group_name                       = var.resource_group_name
    location                                  = var.location
    app_name                                  = var.app_name
    bastion_subnet_id                         = coalesce(var.bastion_subnet_id, "")
    bastion_sku                               = var.bastion_sku
    bastion_tunneling_enabled                 = tostring(var.bastion_tunneling_enabled)
    bastion_copy_paste_enabled                = tostring(var.bastion_copy_paste_enabled)
    bastion_file_copy_enabled                 = tostring(var.bastion_file_copy_enabled)
    bastion_ip_connect_enabled                = tostring(var.bastion_ip_connect_enabled)
    bastion_shareable_link_enabled            = tostring(var.bastion_shareable_link_enabled)
    bastion_scale_units                       = tostring(var.bastion_scale_units)
    bastion_public_ip_sku                     = var.bastion_public_ip_sku
    bastion_public_ip_sku_tier                = var.bastion_public_ip_sku_tier
    bastion_public_ip_allocation_method       = var.bastion_public_ip_allocation_method
    bastion_public_ip_version                 = var.bastion_public_ip_version
    bastion_public_ip_idle_timeout_in_minutes = tostring(var.bastion_public_ip_idle_timeout_in_minutes)
    bastion_public_ip_ddos_protection_mode    = var.bastion_public_ip_ddos_protection_mode
    common_tags_json                          = jsonencode(var.common_tags)
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.weekday_create_bastion[0].name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "delete_bastion" {
  count                    = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                     = "Delete-BastionHost"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name

  content = templatefile("${path.module}/scripts/delete_bastion.py", {
    subscription_id     = data.azurerm_subscription.current.subscription_id
    resource_group_name = var.resource_group_name
    app_name            = var.app_name
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.daily_delete_bastion[0].name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

locals {
  automation_schedule_timezone             = "UTC"
  automation_weekday_start_time_utc        = "16:00:00Z"
  automation_daily_delete_bastion_time_utc = "01:00:00Z"
}

resource "azurerm_automation_schedule" "weekday_start" {
  name                    = "Weekday-1600UTC-Start"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Week"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_weekday_start_time_utc}"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "weekday_create_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Weekday-1600UTC-Create-Bastion"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Week"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_weekday_start_time_utc}"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "daily_delete_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Daily-0100UTC-Delete-Bastion"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Day"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_daily_delete_bastion_time_utc}"

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_role_assignment" "automation_network_contributor" {
  count                = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_bastion_subnet_network_contributor" {
  count = var.enable_bastion && var.enable_bastion_automation ? 1 : 0

  scope                = var.bastion_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
  lifecycle {
    precondition {
      condition     = var.bastion_subnet_id != null
      error_message = "bastion_subnet_id must be provided when bastion automation is enabled."
    }
  }
}

# VM-scoped role assignments and the Entra-SSH extension now live in the
# module.vm role_assignments / extensions blocks above.

