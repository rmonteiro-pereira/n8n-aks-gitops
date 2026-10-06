#!/usr/bin/env bash
# Generates the secrets this deployment needs, directly into Key Vault.
#
# They are created here and not by OpenTofu so that no secret value ever
# lands in state. Nothing is printed and nothing touches disk: each value is
# piped from the generator into the vault.
#
# Idempotent and NON-DESTRUCTIVE: a secret that already exists is left
# alone. That matters most for n8n-encryption-key -- overwriting it makes
# every credential stored in n8n undecryptable.
#
# Usage: scripts/seed-secrets.sh <key-vault-name>
set -euo pipefail

VAULT="${1:?usage: $0 <key-vault-name>}"

# name : bytes of entropy
SECRETS=(
  "n8n-encryption-key:32"
  "n8n-redis-password:24"
  "n8n-runners-auth-token:24"
  "grafana-admin-password:18"
)

created=0
kept=0
for entry in "${SECRETS[@]}"; do
  name="${entry%%:*}"
  bytes="${entry##*:}"
  if az keyvault secret show --vault-name "$VAULT" --name "$name" --query id --output tsv >/dev/null 2>&1; then
    echo "keep     ${name} (already exists)"
    kept=$((kept + 1))
    continue
  fi
  # --file /dev/stdin keeps the value out of argv and shell history.
  openssl rand -hex "$bytes" | tr -d '\n' |
    az keyvault secret set --vault-name "$VAULT" --name "$name" --file /dev/stdin --output none
  echo "created  ${name}"
  created=$((created + 1))
done

echo
echo "OK: ${created} created, ${kept} kept, in ${VAULT}."
