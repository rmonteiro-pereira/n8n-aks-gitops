# ─────────────────────────────────────────────────────────────────────────
# Destination of the Postgres backups (base backups + WAL), written by the
# database pods through workload identity.
#
# shared_access_key_enabled = false: there is no account key, so nothing to
# leak and nothing to rotate. It is also exactly what barman's
# `inheritFromAzureAD` expects.
#
# This account is the ONLY copy of the n8n database outside the cluster.
# Versioning and soft delete are here so that a compromised or misconfigured
# writer cannot make the backups disappear in one call.
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_storage_account" "backup" {
  name                = "st${var.workload}${var.environment}bkp${random_string.global.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = var.backup_replication_type

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "postgres" {
  name                  = "n8n-db"
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

# Scoped to the container, not the account.
resource "azurerm_role_assignment" "postgres_backup_writer" {
  scope                = azurerm_storage_container.postgres.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload["postgres_backup"].principal_id
  principal_type       = "ServicePrincipal"
}

# Old blob VERSIONS are not covered by barman's retention policy, which only
# deletes current blobs. Without this rule every WAL segment ever written
# stays billable forever as a non-current version.
resource "azurerm_storage_management_policy" "backup" {
  storage_account_id = azurerm_storage_account.backup.id

  rule {
    name    = "expire-noncurrent-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 30
      }
    }
  }
}
