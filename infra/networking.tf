
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_network
resource "azurerm_virtual_network" "lab" {
  name                = var.network_config.name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  address_space       = [var.network_config.address_space]
  tags                = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/subnet
resource "azurerm_subnet" "lab" {
  for_each = local.subnets

  name                            = each.value.name
  resource_group_name             = azurerm_resource_group.shared.name
  virtual_network_name            = azurerm_virtual_network.lab.name
  address_prefixes                = [each.value.cidr]
  default_outbound_access_enabled = local.subnet_default_outbound_access[each.key]
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/network_security_group
resource "azurerm_network_security_group" "subnets" {
  for_each = local.subnet_rules

  name                = "${var.network_config.name}-${each.key}-nsg"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  dynamic "security_rule" {
    for_each = local.subnet_rules[each.key]
    content {
      name                       = security_rule.key
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = local.nsg_allowed_rule_access
      protocol                   = security_rule.value.protocol
      source_port_range          = local.nsg_source_port_range
      source_address_prefix      = length(security_rule.value.sources) == 1 ? one(security_rule.value.sources) : null
      source_address_prefixes    = length(security_rule.value.sources) > 1 ? security_rule.value.sources : null
      destination_address_prefix = security_rule.value.destination
      destination_port_ranges    = security_rule.value.ports
    }
  }

  security_rule {
    name                       = local.nsg_default_inbound_rule.name
    priority                   = local.nsg_default_inbound_rule.priority
    direction                  = local.nsg_default_inbound_rule.direction
    access                     = local.nsg_default_inbound_rule.access
    protocol                   = local.nsg_default_inbound_rule.protocol
    source_port_range          = local.nsg_default_inbound_rule.source_port_range
    destination_port_range     = local.nsg_default_inbound_rule.destination_port_range
    source_address_prefix      = local.nsg_default_inbound_rule.source_address_prefix
    destination_address_prefix = local.nsg_default_inbound_rule.destination_address_prefix
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association
resource "azurerm_subnet_network_security_group_association" "lab" {
  for_each = local.subnet_rules

  subnet_id                 = azurerm_subnet.lab[each.key].id
  network_security_group_id = azurerm_network_security_group.subnets[each.key].id
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/public_ip
resource "azurerm_public_ip" "bastion" {
  name                = "${local.bastion_name}-pip"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  allocation_method   = local.public_ip_allocation_method
  sku                 = local.public_ip_sku
  tags                = local.tags

  # ip_tags is added after creation by an external principal and forces replacement.
  lifecycle {
    ignore_changes = [ip_tags]
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/bastion_host
resource "azurerm_bastion_host" "lab" {
  name                = local.bastion_name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  sku                 = local.bastion_sku
  tunneling_enabled   = local.bastion_tunneling_enabled
  tags                = local.tags

  ip_configuration {
    name                 = local.bastion_ip_configuration_name
    subnet_id            = azurerm_subnet.lab["bastion"].id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/public_ip
resource "azurerm_public_ip" "egress" {
  name                = "${var.network_config.name}-egress-pip"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  allocation_method   = local.public_ip_allocation_method
  sku                 = local.public_ip_sku
  tags                = local.tags

  # ip_tags is added after creation by an external principal and forces replacement.
  lifecycle {
    ignore_changes = [ip_tags]
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/nat_gateway
resource "azurerm_nat_gateway" "lab" {
  name                = "${var.network_config.name}-nat"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  sku_name            = local.nat_gateway_sku
  tags                = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/nat_gateway_public_ip_association
resource "azurerm_nat_gateway_public_ip_association" "lab" {
  nat_gateway_id       = azurerm_nat_gateway.lab.id
  public_ip_address_id = azurerm_public_ip.egress.id
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/subnet_nat_gateway_association
resource "azurerm_subnet_nat_gateway_association" "lab" {
  for_each = local.nat_gateway_subnets

  subnet_id      = azurerm_subnet.lab[each.key].id
  nat_gateway_id = azurerm_nat_gateway.lab.id
}