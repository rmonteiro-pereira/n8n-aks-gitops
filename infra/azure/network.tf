resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.nodes_subnet_cidr]
}

# The delegation is mandatory for API Server VNet Integration. Without it the
# cluster create fails, and the message talks about an invalid subnet rather
# than a missing delegation.
resource "azurerm_subnet" "apiserver" {
  name                 = "snet-apiserver"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.apiserver_subnet_cidr]

  delegation {
    name = "aks-apiserver"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_endpoints_subnet_cidr]
}

# ─────────────────────────────────────────────────────────────────────────
# Public IPs.
#
# prevent_destroy on both, and the reason is the NUMBER, not the resource.
# A static allocation keeps the address only while the resource lives; once
# destroyed, Azure returns it to the pool and the next create draws another.
#
#   ingress  is what the DNS record points at, and what webhook senders may
#            have allow-listed.
#   egress   is the source address of every outbound call n8n makes. The
#            day a workflow talks to a database or API behind someone else's
#            firewall, this number is in an allow-list you do not control,
#            and losing it breaks silently -- as a connection timeout inside
#            a workflow, not as a network error anyone is watching.
#
# The guard turns three things into a failed plan instead of a destroy: a
# change that forces replacement (zones, sku, name), `tofu destroy` of the
# stack, and removing the resource. Whoever really wants it gone deletes this
# block in its own PR, which is where someone remembers to warn the other side.
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "ingress" {
  name                = "pip-${local.suffix}-ingress"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "egress" {
  name                = "pip-${local.suffix}-egress"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_dns_a_record" "n8n" {
  count = var.dns_zone == null ? 0 : 1

  name                = trimsuffix(var.n8n_hostname, ".${var.dns_zone.name}")
  zone_name           = var.dns_zone.name
  resource_group_name = var.dns_zone.resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.ingress.ip_address]
  tags                = var.tags
}
