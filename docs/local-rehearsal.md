# Local rehearsal

Two ways to run this repository without Azure. Both were used to verify it.

## The n8n chart alone

Any local cluster (k3s, kind) with CloudNativePG and KEDA installed:

```bash
helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts -n cnpg-system --create-namespace --wait
helm upgrade --install keda keda --repo https://kedacore.github.io/charts -n keda --create-namespace --wait

kubectl create namespace n8n
kubectl label namespace n8n pod-security.kubernetes.io/enforce=restricted
kubectl -n n8n create secret generic n8n-secrets \
  --from-literal=encryption-key="$(openssl rand -hex 32)" \
  --from-literal=redis-password="$(openssl rand -hex 24)" \
  --from-literal=runners-auth-token="$(openssl rand -hex 24)"

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
helm upgrade --install n8n gitops/n8n -n n8n -f gitops/n8n/ci/k3s-values.yaml \
  --set "networkPolicy.apiServer.cidrs={${NODE_IP}/32}" \
  --set "networkPolicy.apiServer.ports={6443}"

kubectl -n n8n port-forward svc/n8n-main 5678:5678      # editor
kubectl -n n8n port-forward svc/n8n-webhook 5679:5678   # production webhooks
```

The secure-cookie setting expects HTTPS; for a plain port-forward add
`--set extraEnv.N8N_SECURE_COOKIE=false`.

## The whole GitOps tree

ArgoCD needs to pull from somewhere, and three pieces are bound to Azure or to
a public DNS name. On a throwaway branch, replace them with local stand-ins:

| File | Stand-in |
|---|---|
| `gitops/platform-config/templates/storageclass.yaml` | the cluster's local provisioner, same class name |
| `gitops/platform-config/templates/clustersecretstore.yaml` | External Secrets' `fake` provider, with the four keys from `scripts/seed-secrets.sh` |
| `gitops/platform-config/templates/clusterissuers.yaml` | two `selfSigned` issuers with the same names |

Add `gitops/apps/env/local.yaml` with `repoURL` pointing at wherever the
branch is served from (a `git daemon` on the host works), empty
`azure.backup.destinationPath` (disables backups), `azure.apiServerCidr` set
to the node address as a /32 CIDR (for example `192.168.1.10/32`),
`monitoring.enabled: false`, and under `n8n.values`
single-node sizes (`postgres.instances: 1`) and
`networkPolicy.apiServer.ports: [6443]`.

Then do by hand what `infra/bootstrap` does:

```bash
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  -n argocd --create-namespace -f infra/bootstrap/values-argocd.yaml --wait
helm upgrade --install project infra/bootstrap/charts/project -n argocd --set repoUrl=<repo>
helm upgrade --install root infra/bootstrap/charts/root -n argocd \
  --set repoUrl=<repo> --set targetRevision=<branch> --set environment=local
```

KEDA must be installed in `kube-system` (where the AKS add-on puts it), and
the cluster needs something that assigns an address to `LoadBalancer`
Services — the Gateway is not `Programmed` without one, and the waves stop
there, as they should.
