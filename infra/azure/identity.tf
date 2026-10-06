# ─────────────────────────────────────────────────────────────────────────
# One user-assigned identity PER CONSUMER.
#
# The shortcut is one identity federated to every ServiceAccount that needs
# Azure, with a vault-wide role. It works, and it means anything that can
# mint a token for any of those ServiceAccounts reads everything.
#
# ArgoCD is deliberately NOT in this map. The repo-server renders Helm over
# repository content; it needs no vault and no storage. Federating it would
# let a template rendered from a pull request trade its token for an Entra
# token. Do not add it.
# ─────────────────────────────────────────────────────────────────────────
locals {
  workloads = {
    # External Secrets Operator: reads the vault, materialises Secrets.
    eso = {
      namespace       = local.k8s.eso_namespace
      service_account = local.k8s.eso_sa
    }
    # Postgres backups. The subject is the ServiceAccount CloudNativePG
    # creates for the instance pods, which carries the NAME OF THE CLUSTER.
    # Federating a hand-made "backup" account instead yields a Cluster
    # that tries to archive and fails authentication forever -- worse than no
    # backup, because it looks configured.
    postgres_backup = {
      namespace       = local.k8s.n8n_namespace
      service_account = local.k8s.postgres_cluster
    }
  }
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workloads

  name                = "uami-${local.suffix}-${replace(each.key, "_", "-")}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.workloads

  name                = "${each.value.namespace}-${each.value.service_account}"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}
