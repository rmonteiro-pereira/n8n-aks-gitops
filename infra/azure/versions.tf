terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Partial configuration: the storage account that holds state is created
  # out of band (scripts/create-tfstate.sh) and passed with
  #   tofu init -backend-config=backend.hcl
  # State is reachable with Entra ID only -- no account key exists to leak.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # The backup storage account has shared keys disabled. Without this the
  # provider polls the data plane with an account key and the apply dies in
  # KeyBasedAuthenticationNotPermitted.
  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}
