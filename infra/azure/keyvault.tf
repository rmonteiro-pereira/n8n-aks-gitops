# ─────────────────────────────────────────────────────────────────────────
# One vault for this one application. Azure RBAC does accept a scope on a
# single secret, but that turns into one role assignment per key; a vault per
# application is the boundary that stays maintainable.
#
# Terraform creates the vault and the access to it. It does NOT create the
# secret values: anything written through a resource ends up in state.
# scripts/seed-secrets.sh generates them straight into the vault.
#
# purge_protection is what protects N8N_ENCRYPTION_KEY. Every credential
# stored in n8n is encrypted with it; a database backup without that key
# restores workflows whose credentials can never be decrypted again.
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_key_vault" "main" {
  name                = "kv-${var.workload}-${var.environment}-${random_string.global.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  public_network_access_enabled = !var.enable_key_vault_private_endpoint

  network_acls {
    bypass         = "AzureServices"
    default_action = var.enable_key_vault_private_endpoint ? "Deny" : "Allow"
  }

  tags = var.tags
}

# ESO reads the whole vault -- it is the only reader. The real control is that
# every ExternalSecret is a pointer versioned in git, landing in a namespace
# with default-deny.
resource "azurerm_role_assignment" "eso_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload["eso"].principal_id
  principal_type       = "ServicePrincipal"
}

# The people who seed and rotate secrets.
resource "azurerm_role_assignment" "admin_secrets_officer" {
  for_each = toset(var.admin_principal_ids)

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# ── Optional private endpoint ─────────────────────────────────────────────
resource "azurerm_private_dns_zone" "kv" {
  count               = var.enable_key_vault_private_endpoint ? 1 : 0
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  count                 = var.enable_key_vault_private_endpoint ? 1 : 0
  name                  = "link-${azurerm_virtual_network.main.name}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.kv[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "kv" {
  count = var.enable_key_vault_private_endpoint ? 1 : 0

  name                = "pe-${local.suffix}-keyvault"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "keyvault"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv[0].id]
  }

  tags = var.tags
}
