variable "subscription_id" {
  description = "Subscription that receives every resource of this stack."
  type        = string
}

variable "workload" {
  description = "Short workload name, used in every resource name."
  type        = string
  default     = "n8n"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.workload))
    error_message = "workload must be 2-8 lowercase alphanumerics (it lands in Key Vault and storage account names)."
  }
}

variable "environment" {
  description = "Environment name, used in every resource name."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.environment))
    error_message = "environment must be 2-5 lowercase alphanumerics."
  }
}

variable "location" {
  description = "Azure region. Must offer availability zones for the chosen VM size."
  type        = string
  default     = "eastus2"
}

variable "region_code" {
  description = "Region abbreviation used in resource names."
  type        = string
  default     = "eus2"
}

variable "tags" {
  type = map(string)
  default = {
    workload   = "n8n"
    managed_by = "opentofu"
  }
}

# ── Network ────────────────────────────────────────────────────────────────

variable "vnet_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = <<-EOT
    Node subnet. The cluster runs Azure CNI Overlay, so only NODES draw
    addresses from here; pods come from pod_cidr. A /24 is already generous.
  EOT
  type        = string
  default     = "10.42.0.0/24"
}

variable "apiserver_subnet_cidr" {
  description = <<-EOT
    Delegated subnet the control plane is projected into (API Server VNet
    Integration). Minimum /28. Its CIDR is what the NetworkPolicy of the
    database namespace allows as egress -- see the comment in
    gitops/n8n/templates/networkpolicy.yaml.
  EOT
  type        = string
  default     = "10.42.4.0/28"
}

variable "private_endpoints_subnet_cidr" {
  type    = string
  default = "10.42.5.0/27"
}

variable "pod_cidr" {
  description = "Overlay pod CIDR. Must not overlap the VNet or anything it is peered with."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.0.0.10"
}

# ── Cluster ────────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "Minor version (e.g. \"1.33\"). null takes the AKS default at creation; patches follow the auto-upgrade channel."
  type        = string
  default     = null
}

variable "aks_sku_tier" {
  description = "\"Standard\" buys the control-plane uptime SLA. \"Free\" has none and is fine for a rehearsal."
  type        = string
  default     = "Standard"
}

variable "node_pool" {
  description = "The single node pool. n8n, Postgres, the queue and the platform add-ons all schedule here."
  type = object({
    vm_size    = string
    min_count  = number
    max_count  = number
    os_disk_gb = number
    max_pods   = number
  })
  default = {
    vm_size    = "Standard_D4as_v5"
    min_count  = 2
    max_count  = 5
    os_disk_gb = 64
    max_pods   = 60
  }
}

variable "zones" {
  description = <<-EOT
    Availability zones of the node pool. Can only be declared at creation:
    changing it later replaces the pool. Every stateful volume in this repo
    uses a ZRS storage class precisely because of this setting -- an LRS disk
    is zonal and its pod goes Pending the day the autoscaler brings the
    replacement node up in another zone.
  EOT
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "apiserver_allowed_cidrs" {
  description = "CIDRs allowed to reach the public API server endpoint. Empty list = open to the internet (authentication still required)."
  type        = list(string)
  default     = []
}

variable "apiserver_vnet_integration" {
  description = <<-EOT
    Projects the control plane into apiserver_subnet_cidr, giving it a private
    and STABLE address inside the VNet. That is what makes "egress to the API
    server" expressible in a NetworkPolicy under a default-deny namespace:
    with the Cilium dataplane the `kubernetes` ClusterIP is translated before
    policy is evaluated, so the rule sees the backend address -- and without
    this feature the backend is a public IP Azure does not promise to keep.
    Requires a user-assigned cluster identity (this stack always uses one).
  EOT
  type        = bool
  default     = true
}

variable "admin_group_ids" {
  description = "Entra groups that get cluster-admin. Membership changes need a directory role, which is why admin_principal_ids also exists."
  type        = list(string)
  default     = []
}

variable "admin_principal_ids" {
  description = <<-EOT
    Object IDs of the PEOPLE who operate this deployment. Each one gets
    "Azure Kubernetes Service RBAC Cluster Admin" on the cluster and
    "Key Vault Secrets Officer" on the vault. With local accounts disabled
    there is no break-glass kubeconfig, so leaving this (and the group list)
    empty locks everyone out of the cluster.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_ids) > 0
    error_message = "At least one admin principal is required: local accounts are disabled and there is no other way in."
  }
}

variable "container_registry_id" {
  description = "Optional container registry the kubelet may pull from (mirrors, custom n8n image). null = public registries only."
  type        = string
  default     = null
}

# ── Edge / DNS ─────────────────────────────────────────────────────────────

variable "n8n_hostname" {
  description = "Public FQDN of n8n, e.g. n8n.example.com."
  type        = string
}

variable "dns_zone" {
  description = "Azure DNS zone to create the A record in. null = you create the record yourself, pointing at the ingress_ip output."
  type = object({
    name                = string
    resource_group_name = string
  })
  default = null
}

variable "acme_email" {
  description = "Contact e-mail registered with Let's Encrypt."
  type        = string
}

# ── Key Vault ──────────────────────────────────────────────────────────────

variable "enable_key_vault_private_endpoint" {
  description = "Closes the vault's public endpoint and reaches it through a private endpoint. Operators then need a path into the VNet to seed or rotate secrets."
  type        = bool
  default     = false
}

# ── Backups ────────────────────────────────────────────────────────────────

variable "backup_replication_type" {
  description = "Replication of the Postgres backup account. GRS keeps a copy in the paired region."
  type        = string
  default     = "GRS"
}

# ── Observability and cost ─────────────────────────────────────────────────

variable "audit_log_retention_days" {
  type    = number
  default = 30
}

variable "audit_log_daily_cap_gb" {
  description = "Hard daily ingestion cap of the audit workspace. -1 disables the cap."
  type        = number
  default     = 1
}

variable "budget" {
  description = "Monthly cost budget on the resource group. null disables it. start_date must be the first day of a month (RFC 3339)."
  type = object({
    amount         = number
    start_date     = string
    contact_emails = list(string)
  })
  default = null
}

# ── GitOps ─────────────────────────────────────────────────────────────────

variable "gitops_repo_url" {
  description = "URL ArgoCD pulls this repository from. Only echoed into the generated environment values file."
  type        = string
}
