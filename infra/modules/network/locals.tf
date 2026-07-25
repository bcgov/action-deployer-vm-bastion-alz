locals {
  bastion_subnet_cidr = var.bastion_subnet_address_prefix
  jumpbox_subnet_cidr = var.jumpbox_subnet_address_prefix

  # Cross-check the caller-supplied vnet_address_space against the address
  # space Azure actually returns for the resolved VNet, and verify both subnet
  # prefixes are contained within that real address space -- using the
  # discovered value, not just the caller's claim, so a stale secret or a
  # subnet CIDR outside the VNet fails fast in plan instead of surfacing as an
  # opaque Azure API error in apply. Enforced via the check block in main.tf.
  vnet_address_space_matches_discovered = contains(data.azurerm_virtual_network.main.address_space, var.vnet_address_space)

  subnet_prefixes_to_check = {
    bastion_subnet_address_prefix = local.bastion_subnet_cidr
    jumpbox_subnet_address_prefix = local.jumpbox_subnet_cidr
  }

  subnet_containment = {
    for name, cidr in local.subnet_prefixes_to_check : name => anytrue([
      for vnet_cidr in data.azurerm_virtual_network.main.address_space :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", vnet_cidr)[1]) &&
      cidrhost(vnet_cidr, 0) == cidrhost("${cidrhost(cidr, 0)}/${split("/", vnet_cidr)[1]}", 0)
    ])
  }
}
