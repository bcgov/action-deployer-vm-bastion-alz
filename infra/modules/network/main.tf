data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# A `check` block (not a postcondition on the data source itself) so the
# locals it references can depend on the data source's own attribute without
# creating a dependency cycle back onto that same data source.
check "vnet_and_subnets_consistent" {
  assert {
    condition     = local.vnet_address_space_matches_discovered
    error_message = "vnet_address_space (${var.vnet_address_space}) does not match any address space on VNet '${var.vnet_name}' (actual: ${join(", ", data.azurerm_virtual_network.main.address_space)}). Update vnet_address_space to the real VNet address space."
  }

  assert {
    condition     = local.subnet_containment["bastion_subnet_address_prefix"]
    error_message = "bastion_subnet_address_prefix (${var.bastion_subnet_address_prefix}) is not contained within the address space of VNet '${var.vnet_name}' (${join(", ", data.azurerm_virtual_network.main.address_space)})."
  }

  assert {
    condition     = local.subnet_containment["jumpbox_subnet_address_prefix"]
    error_message = "jumpbox_subnet_address_prefix (${var.jumpbox_subnet_address_prefix}) is not contained within the address space of VNet '${var.vnet_name}' (${join(", ", data.azurerm_virtual_network.main.address_space)})."
  }
}


# -----------------------------------------------------------------------------
# Jumpbox VM Subnet and NSG
# -----------------------------------------------------------------------------

# NSG for Jumpbox subnet
resource "azurerm_network_security_group" "jumpbox" {
  name                = "${var.resource_group_name}-jumpbox-nsg"
  location            = var.location
  resource_group_name = var.vnet_resource_group_name

  # Allow SSH from Bastion subnet only
  security_rule {
    name                       = "AllowSSHFromBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.bastion_subnet_cidr
    destination_address_prefix = local.jumpbox_subnet_cidr
    source_port_range          = "*"
    destination_port_range     = "22"
  }

  # Allow outbound HTTPS to internet (for package updates, Azure CLI, etc.)
  security_rule {
    name                       = "AllowOutboundHTTPS"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.jumpbox_subnet_cidr
    destination_address_prefix = "Internet"
    source_port_range          = "*"
    destination_port_range     = "443"
  }

  # Allow outbound HTTP (for package updates)
  security_rule {
    name                       = "AllowOutboundHTTP"
    priority                   = 111
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.jumpbox_subnet_cidr
    destination_address_prefix = "Internet"
    source_port_range          = "*"
    destination_port_range     = "80"
  }

  # Allow outbound DNS
  security_rule {
    name                       = "AllowOutboundDNS"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = local.jumpbox_subnet_cidr
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "53"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

# Jumpbox subnet
resource "azapi_resource" "jumpbox_subnet" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-04-01"
  name      = var.jumpbox_subnet_name
  parent_id = data.azurerm_virtual_network.main.id
  locks     = [data.azurerm_virtual_network.main.id]
  body = {
    properties = {
      addressPrefix = local.jumpbox_subnet_cidr
      networkSecurityGroup = {
        id = azurerm_network_security_group.jumpbox.id
      }
    }
  }
  response_export_values = ["*"]
}

# -----------------------------------------------------------------------------
# Azure Bastion Subnet and NSG
# -----------------------------------------------------------------------------

# NSG for Azure Bastion subnet (required rules per Microsoft documentation)
resource "azurerm_network_security_group" "bastion" {
  name                = "${var.resource_group_name}-bastion-nsg"
  location            = var.location
  resource_group_name = var.vnet_resource_group_name

  # Inbound Rules

  # Allow HTTPS inbound from Internet (for Bastion portal access)
  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "443"
  }

  # Allow Gateway Manager inbound (required for Bastion control plane)
  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "443"
  }

  # Allow Azure Load Balancer inbound (required for health probes)
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "443"
  }

  # Allow Bastion host communication
  security_rule {
    name                       = "AllowBastionHostCommunication"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
  }

  # Outbound Rules

  # Allow SSH outbound to VNet (for connecting to VMs)
  security_rule {
    name                       = "AllowSshOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
    source_port_range          = "*"
    destination_port_range     = "22"
  }

  security_rule {
    name                       = "AllowRdpOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
    source_port_range          = "*"
    destination_port_range     = "3389"
  }

  # Allow Azure Cloud outbound (for Bastion control plane)
  security_rule {
    name                       = "AllowAzureCloudOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
    source_port_range          = "*"
    destination_port_range     = "443"
  }

  # Allow Bastion host communication outbound
  security_rule {
    name                       = "AllowBastionCommunicationOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
  }

  # Allow HTTP outbound for session information
  security_rule {
    name                       = "AllowHttpOutbound"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
    source_port_range          = "*"
    destination_port_range     = "80"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

# Azure Bastion subnet (must be named "AzureBastionSubnet")
resource "azapi_resource" "bastion_subnet" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-04-01"
  name      = var.bastion_subnet_name # Must be "AzureBastionSubnet"
  parent_id = data.azurerm_virtual_network.main.id
  locks     = [data.azurerm_virtual_network.main.id]
  body = {
    properties = {
      addressPrefix = local.bastion_subnet_cidr
      networkSecurityGroup = {
        id = azurerm_network_security_group.bastion.id
      }
    }
  }
  response_export_values = ["*"]
  depends_on             = [azapi_resource.jumpbox_subnet]
}
