# Calculate subnet CIDRs based on VNet address space
locals {
  # Split the address space
  vnet_ip_base = split("/", var.vnet_address_space)[0]
  octets       = split(".", local.vnet_ip_base)
  base_ip      = "${local.octets[0]}.${local.octets[1]}.${local.octets[2]}"

  # Explicit subnet prefixes take precedence. When left empty they are derived
  # from the VNet base address, which assumes a /24 spoke (the ALZ standard):
  # bastion -> <base>.64/26, jumpbox -> <base>.128/28. For other VNet sizes,
  # set bastion_subnet_address_prefix / jumpbox_subnet_address_prefix explicitly.
  bastion_subnet_cidr = var.bastion_subnet_address_prefix != "" ? var.bastion_subnet_address_prefix : "${local.base_ip}.64/26"
  jumpbox_subnet_cidr = var.jumpbox_subnet_address_prefix != "" ? var.jumpbox_subnet_address_prefix : "${local.base_ip}.128/28"
}
