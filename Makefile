# Everything CI runs, runnable locally. Needs: tofu, helm, kubeconform, shellcheck.
TF ?= tofu
ENV ?= prod
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
KUBECONFORM := kubeconform -strict -summary -ignore-missing-schemas -schema-location default -schema-location '$(CRD_SCHEMAS)'

# Stand-in values so the n8n chart renders with every optional block on.
N8N_FULL := --set postgres.backup.enabled=true \
	--set postgres.backup.clientId=00000000-0000-0000-0000-000000000000 \
	--set postgres.backup.destinationPath=https://example.blob.core.windows.net/n8n-db \
	--set 'networkPolicy.apiServer.cidrs={10.42.4.0/28}'

.PHONY: validate fmt tf-validate helm-lint manifests shellcheck

validate: fmt tf-validate helm-lint manifests

fmt:
	$(TF) fmt -check -recursive infra

tf-validate:
	@for stack in infra/azure infra/bootstrap; do \
		echo "==> $$stack"; \
		$(TF) -chdir=$$stack init -backend=false -input=false >/dev/null && \
		$(TF) -chdir=$$stack validate || exit 1; \
	done

helm-lint:
	helm lint gitops/apps -f gitops/apps/env/$(ENV).yaml
	helm lint gitops/platform-config -f gitops/platform-config/ci/values.yaml
	helm lint gitops/n8n $(N8N_FULL)
	helm lint infra/bootstrap/charts/project --set repoUrl=https://example.com/repo.git
	helm lint infra/bootstrap/charts/root --set repoUrl=https://example.com/repo.git

manifests:
	helm template apps gitops/apps -f gitops/apps/env/$(ENV).yaml | $(KUBECONFORM)
	helm template platform-config gitops/platform-config -f gitops/platform-config/ci/values.yaml | $(KUBECONFORM)
	helm template n8n gitops/n8n -n n8n $(N8N_FULL) | $(KUBECONFORM)
	helm template n8n gitops/n8n -n n8n $(N8N_FULL) --set postgres.recovery.enabled=true --set postgres.backup.serverName=n8n-db-r1 | $(KUBECONFORM)
	helm template n8n gitops/n8n -n n8n -f gitops/n8n/ci/k3s-values.yaml | $(KUBECONFORM)

shellcheck:
	shellcheck scripts/*.sh
