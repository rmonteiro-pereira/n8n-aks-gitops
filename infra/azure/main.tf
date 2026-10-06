data "azurerm_client_config" "current" {}

locals {
  suffix = "${var.workload}-${var.environment}-${var.region_code}"

  # Kubernetes coordinates the Azure side has to agree with. They are locals
  # and not variables on purpose: federated credentials are matched on the
  # literal `system:serviceaccount:<ns>:<sa>` subject, and the Helm values in
  # gitops/ use the same names. A tfvars override here would silently produce
  # an identity nobody can assume.
  k8s = {
    n8n_namespace = "n8n"
    # CloudNativePG runs the instance pods under a ServiceAccount named after
    # the Cluster resource. That -- not some standalone "backup" account -- is
    # the identity that archives WAL and takes base backups.
    postgres_cluster = "n8n-db"
    eso_namespace    = "external-secrets"
    eso_sa           = "external-secrets"
    gateway_ns       = "envoy-gateway-system"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.suffix}"
  location = var.location
  tags     = var.tags
}

# Global names (Key Vault, storage) need something unique; a short random
# suffix keeps them inside the 24-character limit both resources share.
resource "random_string" "global" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}
