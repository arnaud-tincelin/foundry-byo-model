#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-github-deploy.sh
#
# Creates the Azure AD app registration, service principal, and federated
# identity credential needed for the GitHub Actions deploy workflow (OIDC).
# Then assigns Contributor and User Access Administrator roles on the
# current subscription.
#
# Prerequisites:
#   - Azure CLI installed and logged in (`az login`)
#   - Sufficient permissions to create app registrations and role assignments
#
# Usage:
#   ./scripts/setup-github-deploy.sh
#   ./scripts/setup-github-deploy.sh --subscription <subscription-id>
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DISPLAY_NAME="foundry-byo-model-deploy"
REPO="arnaud-tincelin/foundry-byo-model"
ENVIRONMENT="production"

# ---------------------------------------------------------------------------
# Parse optional --subscription flag; otherwise detect from current context
# ---------------------------------------------------------------------------
SUB_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription|-s)
      SUB_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--subscription <subscription-id>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SUB_ID" ]]; then
  SUB_ID=$(az account show --query "id" -o tsv 2>/dev/null) || true
  if [[ -z "$SUB_ID" ]]; then
    echo "ERROR: Could not determine the Azure subscription ID." >&2
    echo "Log in with 'az login' or pass --subscription <id>." >&2
    exit 1
  fi
  echo "Using current subscription: $SUB_ID"
fi

# ---------------------------------------------------------------------------
# 1. Create or reuse the app registration
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating app registration '${APP_DISPLAY_NAME}'..."
EXISTING_APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null) || true

if [[ -n "$EXISTING_APP_ID" ]]; then
  APP_ID="$EXISTING_APP_ID"
  echo "    App registration already exists (appId: ${APP_ID})"
else
  az ad app create --display-name "$APP_DISPLAY_NAME" -o none
  APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv)
  echo "    Created app registration (appId: ${APP_ID})"
fi

# ---------------------------------------------------------------------------
# 2. Create or reuse the service principal
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating service principal..."
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null) || true

if [[ -n "$SP_OBJECT_ID" ]]; then
  echo "    Service principal already exists (objectId: ${SP_OBJECT_ID})"
else
  az ad sp create --id "$APP_ID" -o none
  SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv)
  echo "    Created service principal (objectId: ${SP_OBJECT_ID})"
fi

# ---------------------------------------------------------------------------
# 3. Add federated credential for GitHub Actions OIDC
# ---------------------------------------------------------------------------
echo ""
echo "==> Adding federated identity credential for GitHub Actions..."
FIC_EXISTS=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='github-deploy'].name" -o tsv 2>/dev/null) || true

if [[ -n "$FIC_EXISTS" ]]; then
  echo "    Federated credential 'github-deploy' already exists — skipping."
else
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-deploy\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:${ENVIRONMENT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
  echo "    Created federated credential 'github-deploy'."
fi

# ---------------------------------------------------------------------------
# 4. Assign roles on the subscription
# ---------------------------------------------------------------------------
SCOPE="/subscriptions/${SUB_ID}"

echo ""
echo "==> Assigning Contributor role on subscription ${SUB_ID}..."
az role assignment create \
  --assignee "$SP_OBJECT_ID" \
  --role "Contributor" \
  --scope "$SCOPE" \
  -o none 2>/dev/null || echo "    (Role may already be assigned)"

echo "==> Assigning Role Based Access Control Administrator role on subscription ${SUB_ID}..."
az role assignment create \
  --assignee "$SP_OBJECT_ID" \
  --role "Role Based Access Control Administrator" \
  --scope "$SCOPE" \
  -o none 2>/dev/null || echo "    (Role may already be assigned)"

echo "==> Assigning Azure AI Project Manager role on subscription ${SUB_ID}..."
az role assignment create \
  --assignee "$SP_OBJECT_ID" \
  --role "Azure AI Project Manager" \
  --scope "$SCOPE" \
  -o none 2>/dev/null || echo "    (Role may already be assigned)"

# ---------------------------------------------------------------------------
# 5. Print summary with GitHub secrets to configure
# ---------------------------------------------------------------------------
TENANT_ID=$(az account show --query "tenantId" -o tsv)

echo ""
echo "==========================================================="
echo " Setup complete!"
echo "==========================================================="
echo ""
echo "Configure the following secrets in your GitHub repository"
echo "(Settings > Environments > '${ENVIRONMENT}' > Secrets):"
echo ""
echo "  AZURE_CLIENT_ID        = ${APP_ID}"
echo "  AZURE_TENANT_ID        = ${TENANT_ID}"
echo "  AZURE_SUBSCRIPTION_ID  = ${SUB_ID}"
echo "  AZURE_LOCATION         = <your preferred Azure region, e.g. eastus2>"
echo "  APIM_PUBLISHER_EMAIL   = <your email address>"
echo ""
