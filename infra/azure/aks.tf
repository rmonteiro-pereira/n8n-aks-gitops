# ─────────────────────────────────────────────────────────────────────────
# Control-plane identity: user-assigned, created BEFORE the cluster.
#
# A system-assigned identity only exists once the cluster does, so there is no
# way to pre-grant it a role on a subnet the control plane must reach while it
# is being created. API Server VNet Integration refuses it outright
# (OnlySupportedOnUserAssignedMSICluster). With a user-assigned identity the
# order inverts: identity first, roles second, cluster third.
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "uami-${local.suffix}-cluster"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = var.tags
}

# Per SUBNET, not on the VNet: it is all the cluster needs, and a VNet-wide
# grant would follow the identity into any subnet added later. AKS wants the
# role on both -- missing it on the API server subnet fails provisioning.
resource "azurerm_role_assignment" "cluster_subnets" {
  for_each = {
    nodes     = azurerm_subnet.nodes.id
    apiserver = azurerm_subnet.apiserver.id
  }

  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# Both public IPs live outside the node resource group, so the cluster
# identity needs `publicIPAddresses/join/action` on them.
#
# The EGRESS one is not obvious. Creating the edge Service does a PUT on the
# single `kubernetes` Load Balancer, and that PUT re-validates the join of
# EVERY frontend on the object -- including the outbound one AKS attached at
# creation. Without the role the edge Service sits at EXTERNAL-IP <pending>
# with a healthy controller pod, and the only clue is a 403
# LinkedAuthorizationFailed in the cloud-controller events. This is
# cloud-provider-azure behaviour, so it is the same for any ingress or
# gateway controller.
resource "azurerm_role_assignment" "cluster_public_ips" {
  for_each = {
    ingress = azurerm_public_ip.ingress.id
    egress  = azurerm_public_ip.egress.id
  }

  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# A role assignment that exists is not yet a role assignment that is
# honoured: Azure RBAC takes a minute or two to propagate. AKS checks the
# identity's permissions on the subnets and the outbound IP while it creates
# the cluster, and `depends_on` alone only orders the API calls. If a create
# does fail on authorization anyway, the cluster may exist in Azure in a
# Failed state without being in state -- delete it (`az aks delete`) before
# applying again.
resource "time_sleep" "cluster_roles" {
  create_duration = "120s"

  depends_on = [
    azurerm_role_assignment.cluster_subnets,
    azurerm_role_assignment.cluster_public_ips,
  ]
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  dns_prefix          = "aks-${local.suffix}"
  kubernetes_version  = var.kubernetes_version
  node_resource_group = "rg-${local.suffix}-nodes"

  sku_tier = var.aks_sku_tier

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # No local account: no cluster-admin certificate exists, so none can end up
  # in state or in someone's kubeconfig. Access is Entra ID + kubelogin.
  local_account_disabled = true

  # `az aks command invoke` runs an arbitrary command inside the cluster
  # through ARM, in an ephemeral pod. It bypasses NetworkPolicy, the API
  # server IP allow-list and private clusters alike, because it goes through
  # none of them. It is on by default.
  run_command_enabled = false

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.admin_group_ids
    azure_rbac_enabled     = true
  }

  api_server_access_profile {
    authorized_ip_ranges                = var.apiserver_allowed_cidrs
    virtual_network_integration_enabled = var.apiserver_vnet_integration
    subnet_id                           = var.apiserver_vnet_integration ? azurerm_subnet.apiserver.id : null
  }

  default_node_pool {
    name       = "system"
    vm_size    = var.node_pool.vm_size
    node_count = var.node_pool.min_count

    auto_scaling_enabled = true
    min_count            = var.node_pool.min_count
    max_count            = var.node_pool.max_count

    os_disk_size_gb = var.node_pool.os_disk_gb
    os_disk_type    = "Managed"
    max_pods        = var.node_pool.max_pods
    vnet_subnet_id  = azurerm_subnet.nodes.id
    zones           = var.zones

    # vm_size, max_pods and zones on the default pool are ForceNew. Without a
    # temporary name the plan becomes destroy/create of the whole cluster;
    # with it the provider brings up an intermediate pool, migrates and
    # removes the old one. ZRS volumes survive the move.
    temporary_name_for_rotation = "systemtmp"

    # false on purpose. true applies the CriticalAddonsOnly taint and, in a
    # single-pool design, nothing of the application ever schedules.
    only_critical_addons_enabled = false

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_profile {
      outbound_ip_address_ids = [azurerm_public_ip.egress.id]
    }
  }

  # KEDA as the managed add-on: it is what scales the n8n workers on queue
  # depth. Without it the ScaledObject in gitops/n8n has no CRD and the
  # ArgoCD sync fails. VPA stays off -- nothing here asks for it, and it would
  # be one more controller writing to pod specs.
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = false
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Sunday"
    start_time  = "06:00"
    utc_offset  = "+00:00"
    duration    = 4
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Sunday"
    start_time  = "06:00"
    utc_offset  = "+00:00"
    duration    = 4
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # the autoscaler decides
      kubernetes_version,              # auto-upgrade decides patches
    ]
  }

  # The roles must exist, and have propagated, before the control plane
  # tries to use them.
  depends_on = [time_sleep.cluster_roles]
}

resource "azurerm_role_assignment" "registry_pull" {
  count = var.container_registry_id == null ? 0 : 1

  scope                            = var.container_registry_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Cluster-admin for people, by role on the resource instead of by group
# membership. `admin_group_object_ids` accepts only groups, and adding a member
# to an Entra group takes a DIRECTORY role -- Owner of the subscription is not
# enough. Without this assignment the person who owns the resource group can
# have no access at all to the cluster they just created.
resource "azurerm_role_assignment" "cluster_admins" {
  for_each = toset(var.admin_principal_ids)

  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
