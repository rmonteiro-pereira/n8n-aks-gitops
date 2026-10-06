terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

data "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  resource_group_name = var.resource_group_name
}

# The cluster has no local account, so there is no client certificate to read
# from the data source. Both providers authenticate the way a person does:
# kubelogin exchanging the current `az login` for an AKS token. The server-id
# is the well-known application ID of the AKS Entra server, the same in every
# tenant.
locals {
  kube_host = data.azurerm_kubernetes_cluster.main.kube_config[0].host
  kube_ca   = base64decode(data.azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)

  kubelogin_args = [
    "get-token",
    "--login", "azurecli",
    "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
  ]
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = local.kubelogin_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = local.kubelogin_args
    }
  }
}
