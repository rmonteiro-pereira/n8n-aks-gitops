resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────
# The one declared exception to "no secret passes through state": the
# credential ArgoCD uses to read a private repository.
#
# It is circular by nature. The component that would materialise this Secret
# is External Secrets, and External Secrets is installed BY ArgoCD. So it
# leaves from here, read from the vault through a data source. The value does
# pass through state -- which is the reason the state container is
# Entra-ID-only.
#
# Kept as an isolated, optional pair of resources on purpose: with a public
# repository none of this exists.
# ─────────────────────────────────────────────────────────────────────────
data "azurerm_key_vault" "main" {
  count = var.deploy_key_secret_name == null ? 0 : 1

  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

data "azurerm_key_vault_secret" "deploy_key" {
  count = var.deploy_key_secret_name == null ? 0 : 1

  name         = var.deploy_key_secret_name
  key_vault_id = data.azurerm_key_vault.main[0].id
}

resource "kubernetes_secret_v1" "repository" {
  count = var.deploy_key_secret_name == null ? 0 : 1

  metadata {
    name      = "repo-gitops"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.gitops_repo_url
    sshPrivateKey = data.azurerm_key_vault_secret.deploy_key[0].value
  }

  type = "Opaque"
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version

  wait          = true
  wait_for_jobs = false
  timeout       = 900

  values = [
    file("${path.module}/values-argocd.yaml"),
  ]

  depends_on = [kubernetes_secret_v1.repository]
}

# ─────────────────────────────────────────────────────────────────────────
# The AppProject and the root Application, each in its OWN release. This is
# ordering, not tidiness.
#
# They cannot ride along as extra objects of the ArgoCD release: Helm builds
# every object of a release and checks each one's resource mapping against
# the cluster BEFORE applying anything, so a custom resource whose CRD the
# same release installs never fits in that release:
#
#   resource mapping not found for name: "root" namespace: "argocd"
#   no matches for kind "Application" in version "argoproj.io/v1alpha1"
#   ensure CRDs are installed first
#
# `kubernetes_manifest` does not work either, for a different reason: it
# validates the schema at PLAN time, when the CRD does not exist yet --
# `depends_on` does not help.
#
# Separate releases solve it: by the time these run, the CRDs are there.
#
# The AppProject lives here, and not under gitops/, for a second reason:
# project policy must not be a child of the sync it authorises. If the root
# Application both belongs to the project and delivers it, a mistake in the
# project blocks the sync that would fix the project.
# ─────────────────────────────────────────────────────────────────────────
resource "helm_release" "project" {
  name      = "project"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  chart     = "${path.module}/charts/project"

  wait    = true
  timeout = 120

  set = [
    {
      name  = "repoUrl"
      value = var.gitops_repo_url
    },
  ]

  depends_on = [helm_release.argocd]
}

resource "helm_release" "root" {
  name      = "root"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  chart     = "${path.module}/charts/root"

  wait    = true
  timeout = 300

  set = [
    {
      name  = "repoUrl"
      value = var.gitops_repo_url
    },
    {
      name  = "targetRevision"
      value = var.revision
    },
    {
      name  = "environment"
      value = var.environment
    },
  ]

  depends_on = [helm_release.project]
}

# This stack touches no other Kubernetes resource: from the root Application
# onward, ArgoCD is what applies.
#
# What it does NOT do, stated plainly: there is no self-managed ArgoCD
# Application. The ArgoCD release stays owned by this stack, and upgrading it
# is a pull request here, not a sync. Handing ArgoCD the job of upgrading
# itself is a separate decision -- it takes OpenTofu out of the path.
