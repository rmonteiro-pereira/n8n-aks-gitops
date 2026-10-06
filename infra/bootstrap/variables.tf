variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "Output resource_group_name of infra/azure."
  type        = string
}

variable "cluster_name" {
  description = "Output cluster_name of infra/azure."
  type        = string
}

variable "gitops_repo_url" {
  description = "URL ArgoCD pulls this repository from. Use the SSH form when deploy_key_secret_name is set."
  type        = string
}

variable "revision" {
  description = "Branch or tag ArgoCD tracks."
  type        = string
  default     = "main"
}

variable "environment" {
  description = "Selects gitops/apps/env/<environment>.yaml."
  type        = string
  default     = "prod"
}

variable "argocd_version" {
  description = "Version of the argo-cd Helm chart. Upgrading ArgoCD is a change to this value, applied from here."
  type        = string
  default     = "10.9.6"
}

variable "key_vault_name" {
  description = "Only needed with deploy_key_secret_name. Output key_vault_name of infra/azure."
  type        = string
  default     = null
}

variable "deploy_key_secret_name" {
  description = <<-EOT
    Name of the Key Vault secret holding the SSH deploy key ArgoCD uses to
    read a PRIVATE repository. null = the repository is public and needs no
    credential.
  EOT
  type        = string
  default     = null
}
