#!/usr/bin/env bash
# Creates the storage account that holds the OpenTofu state, once.
#
# It lives outside the stacks on purpose: a stack cannot store its state in a
# resource it creates. Entra ID is the only way in -- shared keys are
# disabled -- because the bootstrap stack may put a repository deploy key in
# state.
#
# Idempotent: re-running it changes nothing and prints the same backend
# configuration.
#
# Usage: scripts/create-tfstate.sh <subscription-id> [location] [resource-group]
set -euo pipefail

SUBSCRIPTION="${1:?usage: $0 <subscription-id> [location] [resource-group]}"
LOCATION="${2:-eastus2}"
RG="${3:-rg-tfstate}"
CONTAINER="tfstate"

step() { printf '\n==> %s\n' "$*"; }

step "Resource group ${RG}"
az group create --subscription "$SUBSCRIPTION" --name "$RG" --location "$LOCATION" --output none

step "Storage account"
ACCOUNT="$(az storage account list --subscription "$SUBSCRIPTION" --resource-group "$RG" \
  --query "[?starts_with(name, 'sttfstate')].name | [0]" --output tsv)"
if [[ -z "$ACCOUNT" ]]; then
  ACCOUNT="sttfstate$(openssl rand -hex 5)"
  az storage account create --subscription "$SUBSCRIPTION" --resource-group "$RG" \
    --name "$ACCOUNT" --location "$LOCATION" \
    --sku Standard_GRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false \
    --output none
  echo "created ${ACCOUNT}"
else
  echo "found ${ACCOUNT}"
fi
ACCOUNT_ID="$(az storage account show --subscription "$SUBSCRIPTION" --resource-group "$RG" --name "$ACCOUNT" --query id --output tsv)"

step "Blob versioning and soft delete (a state file overwritten by mistake is recoverable)"
az storage account blob-service-properties update --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" --account-name "$ACCOUNT" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --output none

step "Storage Blob Data Contributor for the signed-in user"
ME="$(az ad signed-in-user show --query id --output tsv)"
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$ACCOUNT_ID" --output none

step "Container ${CONTAINER}"
# Role assignments take a moment to propagate; retry instead of failing.
for attempt in 1 2 3 4 5 6; do
  if az storage container create --account-name "$ACCOUNT" --name "$CONTAINER" \
    --auth-mode login --output none 2>/dev/null; then
    break
  fi
  if [[ "$attempt" == 6 ]]; then
    echo "FAIL: could not create the container (role not propagated?)" >&2
    exit 1
  fi
  echo "waiting for the role assignment to propagate (${attempt}/6)"
  sleep 15
done

step "Done. Put this in infra/azure/backend.hcl and infra/bootstrap/backend.hcl (changing only 'key'):"
cat <<HCL

resource_group_name  = "${RG}"
storage_account_name = "${ACCOUNT}"
container_name       = "${CONTAINER}"
key                  = "n8n-prod/azure.tfstate"   # bootstrap: n8n-prod/bootstrap.tfstate
HCL
