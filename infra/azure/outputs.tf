output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "ingress_ip" {
  description = "Point the DNS A record of n8n_hostname here (done for you when dns_zone is set)."
  value       = azurerm_public_ip.ingress.ip_address
}

output "egress_ip" {
  description = "Source address of every outbound call n8n makes. This is what third parties allow-list."
  value       = azurerm_public_ip.egress.ip_address
}

# There is no kubeconfig output. With local accounts disabled there is no
# admin credential to export; access is `az aks get-credentials` (without
# --admin) plus kubelogin.

# ─────────────────────────────────────────────────────────────────────────
# Everything the GitOps side needs to know about Azure, as one YAML document.
# scripts/render-env-values.sh writes it to gitops/apps/env/prod.yaml, which
# is committed. None of it is secret: client IDs, names and URLs only.
# ─────────────────────────────────────────────────────────────────────────
output "gitops_env_values" {
  value = yamlencode({
    repoURL = var.gitops_repo_url
    host    = var.n8n_hostname
    azure = {
      tenantId      = data.azurerm_client_config.current.tenant_id
      keyVaultUrl   = azurerm_key_vault.main.vault_uri
      apiServerCidr = var.apiserver_vnet_integration ? var.apiserver_subnet_cidr : ""
      ingress = {
        publicIpName          = azurerm_public_ip.ingress.name
        publicIpResourceGroup = azurerm_resource_group.main.name
      }
      identities = {
        externalSecrets = azurerm_user_assigned_identity.workload["eso"].client_id
        postgresBackup  = azurerm_user_assigned_identity.workload["postgres_backup"].client_id
      }
      backup = {
        destinationPath = "${azurerm_storage_account.backup.primary_blob_endpoint}${azurerm_storage_container.postgres.name}"
      }
    }
    acme = {
      email = var.acme_email
    }
  })
}
