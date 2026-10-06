# ─────────────────────────────────────────────────────────────────────────
# Control-plane audit. Application metrics and alerts are in-cluster
# (kube-prometheus-stack, see gitops/); Container Insights stays off.
#
# What is collected here is what the cluster cannot observe about itself:
# who called the API server. `kube-audit-admin` leaves out get/list, which is
# the bulk of the volume and almost none of the forensic value.
#
# The daily cap is a hard stop, not an alert: a chatty controller can turn an
# audit workspace into the largest line of the bill overnight.
# ─────────────────────────────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "audit" {
  name                = "log-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.audit_log_retention_days
  daily_quota_gb      = var.audit_log_daily_cap_gb
  tags                = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "audit"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "guard"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "audit"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log {
    category = "AuditEvent"
  }
}

# A budget on the resource group. It notifies; it does not stop anything.
# The node resource group is a separate scope and is not covered -- node VMs
# are bounded by the autoscaler's max_count instead.
resource "azurerm_consumption_budget_resource_group" "main" {
  count = var.budget == null ? 0 : 1

  name              = "budget-${local.suffix}"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.budget.amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget.start_date
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 80
    threshold_type = "Actual"
    contact_emails = var.budget.contact_emails
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Forecasted"
    contact_emails = var.budget.contact_emails
  }
}
