# Operations

Day-2 procedures. The rule that shapes all of them:

> **The commit is the change.** Every Application runs with `selfHeal`, and the
> root Application manages the others the same way. A `kubectl edit`,
> `kubectl scale` or `kubectl patch` on anything ArgoCD owns is reverted
> within minutes — including an attempt to pause sync on a child Application.
> Change the file, merge, and let it sync.

## Access

```bash
az login
az aks get-credentials -g <resource-group> -n <cluster-name>   # no --admin: there is no local account
kubectl get nodes                                              # kubelogin opens the browser on first use
```

Access to the cluster is the `admin_principal_ids` list (and
`admin_group_ids`) in `infra/azure/terraform.tfvars`.

**ArgoCD** and **Grafana** are not exposed to the internet:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
az keyvault secret show --vault-name <vault> --name grafana-admin-password --query value -o tsv
```

## Is it healthy?

```bash
kubectl -n argocd get applications          # everything Synced / Healthy
kubectl -n n8n get pods,cluster,scaledobject
kubectl -n n8n get externalsecret           # READY True
```

`Synced` means the manifests converged, not that everything you committed ran.
If an Application is `OutOfSync` but `Healthy`, treat it as a fault, not a
cosmetic state: auto-sync has stopped for some reason and later commits are
not being applied.

```bash
kubectl -n argocd get application <app> \
  -o jsonpath='{.status.operationState.phase} {.status.operationState.message}{"\n"}'
```

## Upgrading n8n

1. Read the n8n release notes for breaking changes between the two versions.
2. Change `image.tag` in `gitops/n8n/values.yaml` and `appVersion` in
   `gitops/n8n/Chart.yaml` (Renovate opens this pull request by itself).
   The task-runner sidecar follows the same tag.
3. Merge.

The main pod is replaced first-come (`Recreate`), and runs database migrations
on start; the start-up probe allows ten minutes. Webhook processors and
workers roll one at a time. Workers get `worker.gracefulShutdownSeconds`
(default 300 s) to finish what they are running.

Do not skip major versions, and take a manual backup before one:

```bash
kubectl cnpg backup n8n-db -n n8n        # needs the cnpg kubectl plugin
```

## Scaling

All in `gitops/n8n/values.yaml`, or per environment under `n8n.values` in
`gitops/apps/env/<env>.yaml`.

| Symptom | Change |
|---|---|
| Executions wait in the queue (`N8nQueueBacklog`) | `worker.autoscaling.maxReplicas`, then `worker.concurrency` |
| Workers are OOM-killed | `worker.resources.limits.memory`, or lower `worker.concurrency` |
| Webhook latency under burst | `webhook.replicas` |
| Database volume filling | lower `executions.maxAgeHours`; grow `postgres.storage.size` (online) |
| Nodes full | `node_pool.max_count` in `infra/azure/terraform.tfvars` |

Every worker holds database connections; `postgres.parameters.max_connections`
(200) is the ceiling for `maxReplicas` × pool size plus main and webhooks.

## Secrets

Values live in Key Vault; External Secrets refreshes the Kubernetes Secret
every hour.

| Secret | Rotation |
|---|---|
| `n8n-encryption-key` | **Never.** Changing it makes every stored credential unreadable. |
| `n8n-redis-password` | Set a new version in the vault, wait for (or force) the refresh, then restart Valkey and the n8n workloads together. Queued jobs survive; there is a short interruption. |
| `n8n-runners-auth-token` | New version in the vault, refresh, restart the workers. |
| `grafana-admin-password` | New version in the vault, refresh, restart Grafana. |
| Database password | Owned by CloudNativePG (`n8n-db-app`). |

```bash
openssl rand -hex 24 | tr -d '\n' | az keyvault secret set --vault-name <vault> --name n8n-redis-password --file /dev/stdin -o none
kubectl -n n8n annotate externalsecret n8n-secrets force-sync="$(date +%s)" --overwrite
kubectl -n n8n rollout restart statefulset/n8n-valkey deployment/n8n-main deployment/n8n-webhook deployment/n8n-worker
```

A rollout restart is a live change ArgoCD does not revert: it only touches a
pod-template annotation the manifests do not declare.

## TLS

The Gateway starts on `letsencrypt-staging`. When
`kubectl -n envoy-gateway-system get certificate n8n-tls` shows `READY True`,
set in `gitops/apps/env/prod.yaml`:

```yaml
acme:
  issuer: letsencrypt-prod
```

Renewal is automatic. If issuance fails, the cause is nearly always DNS not
pointing at `ingress_ip`:

```bash
kubectl -n envoy-gateway-system describe certificate n8n-tls
kubectl get challenges -A
```

## Alerts

The rules ship in `gitops/n8n/templates/monitoring.yaml`. Where they are sent
is yours to decide: add `alertmanager.config` (receivers and routes) to the
`valuesObject` in `gitops/apps/templates/kube-prometheus-stack.yaml`, with any
webhook URL or token pulled from Key Vault through an ExternalSecret rather
than written into the values.

| Alert | First look |
|---|---|
| `N8nMainDown` | `kubectl -n n8n logs deploy/n8n-main` — a failed migration or the database unreachable |
| `N8nWebhookProcessorsDown` | same, `deploy/n8n-webhook` |
| `N8nQueueBacklog` | are workers at `maxReplicas`? is one workflow flooding? |
| `N8nWorkerRestarting` | `kubectl -n n8n describe pod` — `OOMKilled` means the memory limit |
| `N8nPostgresNoStandby` | `kubectl -n n8n get cluster n8n-db`, `kubectl -n n8n get pods -l cnpg.io/cluster=n8n-db` |
| `N8nPostgresWalArchivingFailing` | log of the primary pod: almost always the workload identity or its role on the container |
| `N8nPostgresBackupTooOld` | `kubectl -n n8n get backup,scheduledbackup` |
| `N8nVolumeFillingUp` | which PVC; see Scaling |

## Restore

Three different situations.

**A pod, a node or a zone is lost.** Nothing to do. The operator promotes the
standby; disks are zone-redundant.

**Data must go back in time, or the database is gone.** A new Cluster is
created from the backups. `bootstrap` is only read when the Cluster resource
is created, so this is delete-and-recreate, driven from git:

1. Stop writers and take ArgoCD out of the way for the duration, in one commit
   to `gitops/apps/templates/n8n.yaml`: remove the `automated` block from the
   `syncPolicy` of the n8n Application (the helper is shared — override it for
   this Application only). Merge and let the root sync.
2. Delete the database:
   ```bash
   kubectl -n n8n scale deploy n8n-main n8n-webhook n8n-worker --replicas=0
   kubectl -n n8n delete cluster n8n-db
   ```
   The disks are kept (`reclaimPolicy: Retain`) — they are your fallback until
   the restore is confirmed. Delete the released PersistentVolumes and their
   Azure disks afterwards.
3. In `gitops/apps/env/prod.yaml`:
   ```yaml
   n8n:
     values:
       postgres:
         recovery:
           enabled: true
           sourceServerName: n8n-db           # where the backups were written
           targetTime: "2026-10-05T14:30:00Z"   # omit for the latest point
         backup:
           serverName: n8n-db-r1              # the restored cluster writes somewhere NEW
   ```
4. Restore the `automated` sync policy, merge. ArgoCD recreates the Cluster,
   which replays the backup, then starts n8n.
5. Leave `recovery.enabled` and the new `serverName` in place: they describe
   how this Cluster was born and where it archives. For the next restore,
   `sourceServerName` becomes `n8n-db-r1` and `serverName` `n8n-db-r2`.

**The cluster or the region is lost.** Recreate from the top of the README
into a new resource group, with two differences: grant the new
`postgres-backup` identity access to the *existing* backup container (or copy
the container), and copy `n8n-encryption-key` from the old vault into the new
one **before** `scripts/seed-secrets.sh` runs — the script keeps what it
finds. Then deploy with the `recovery` values above.

Rehearse this before you need it. A backup that has never been restored is a
hypothesis.

## Changing the infrastructure

`infra/azure` is applied from a workstation or a pipeline you add; nothing in
this repository applies it automatically. Read the plan for two things in
particular:

- **A replace of the cluster or of the default node pool.** `vm_size`,
  `max_pods` and `zones` are handled by a temporary pool rotation; a change to
  the subnets or the network profile is a new cluster.
- **A destroy of either public IP.** The plan fails by design
  (`prevent_destroy`). If that is really intended, removing the guard is its
  own pull request — and the moment to warn whoever has the egress address in
  an allow-list.

Upgrading ArgoCD itself is `argocd_version` in `infra/bootstrap`,
applied from there; ArgoCD does not manage its own installation.

## Tearing it down

```bash
tofu -chdir=infra/bootstrap destroy
# remove the prevent_destroy blocks from infra/azure/network.tf, then:
tofu -chdir=infra/azure destroy
```

The Key Vault is soft-deleted and stays recoverable for 90 days (purge
protection cannot be turned off); its name is unavailable until then. Disks
created with the `Retain` storage class outlive the cluster in the node
resource group's lifetime — check for orphaned disks.
