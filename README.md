# Foundry BYO Model

**Bring Your Own Model** to [Azure AI Foundry](https://learn.microsoft.com/azure/ai-studio/) — serve any open-source LLM on a GPU Container App and wire it into Foundry as a first-class model gateway, ready for agents.

This template deploys the full infrastructure with `azd` and registers a sample "Guess My Number" prompt agent that talks to your model.

## Architecture

```
┌────────────────────┐
│  Azure AI Foundry  │
│  (Account+Project) │
└────────┬───────────┘
         │ model gateway connection
         ▼
┌────────────────────┐
│   Azure API Mgmt   │  ← rewrites OpenAI-compatible routes
└────────┬───────────┘
         │
         ▼
┌────────────────────┐
│  vLLM on GPU       │  ← Container App (or any model)
└────────────────────┘
```

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- An Azure subscription with GPU quota

Or open in the provided **Dev Container** which includes all tools.

## Quick Start

```bash
# Log in
azd auth login

# Deploy everything (infra + agent registration)
azd up
```

`azd up` provisions all resources and automatically runs the post-provision hook that registers the Foundry agent.

### Test the agent

```bash
AI_SERVICES_ENDPOINT=$(azd env get-value foundryEndpoint) \
FOUNDRY_PROJECT_NAME=$(azd env get-value foundryProjectName) \
uv run scripts/test-agent.py
```

## Bring Your Own Model

Configure the deployment via `infra/main.bicepparam`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `environmentName` | `production` | Environment name used for resource naming |
| `location` | `swedencentral` | Azure region |
| `apimPublisherEmail` | `admin@contoso.com` | APIM publisher email |

Then re-run `azd up`.

## CI/CD with GitHub Actions

A deploy workflow is provided at `.github/workflows/deploy.yml` using OIDC federated credentials.

### Setup

```bash
# Create the app registration, service principal, and federated credential
./scripts/setup-github-deploy.sh --subscription <subscription-id>
```

The script prints the secrets to configure under **GitHub → Settings → Environments → `production` → Secrets**:

| Secret | Description |
|--------|-------------|
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `AZURE_LOCATION` | Azure region (e.g. `swedencentral`) |
| `APIM_PUBLISHER_EMAIL` | Email for API Management |

Pushes to `main` trigger the workflow automatically.

## Project Structure

```
├── infra/
│   ├── main.bicep          # Core resources (Foundry, Container Apps, model app)
│   ├── apim.bicep          # API Management (gateway, routes, policies)
│   └── main.bicepparam     # Deployment parameters
├── scripts/
│   ├── setup-foundry-agent.py   # Registers the prompt agent in Foundry (post-provision)
│   ├── setup-github-deploy.sh   # OIDC setup for GitHub Actions CI/CD
│   └── test-agent.py            # Interactive agent test client
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions deploy pipeline
├── azure.yaml              # azd project configuration
└── README.md
```
