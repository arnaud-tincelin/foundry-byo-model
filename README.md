# Foundry BYO Model

**Bring Your Own Model** to [Azure AI Foundry](https://learn.microsoft.com/azure/ai-studio/) — serve any LLM and wire it into Foundry as a first-class [model gateway](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/ai-gateway), ready for agents.

This template deploys the full infrastructure with `azd` and registers a sample "Guess My Number" prompt agent that talks to your model.

## Architecture

All resources are deployed in a private VNet. Only APIM is exposed to the internet.

```
                    Internet
                       │
                       ▼
              ┌────────────────┐
              │  Azure APIM    │  ← Only public endpoint (Standard v2, VNet integrated)
              │  (External)    │
              └───────┬────────┘
                      │ VNet
  ┌───────────────────┼───────────────────────┐
  │                   │                       │
  │                   ▼                       │
  │       ┌────────────────────┐              │
  │       │  vLLM on GPU       │  ← Internal  │
  │       │  (Container Apps)  │    only      │
  │       └────────────────────┘              │
  │                                           │
  │       ┌────────────────────┐              │
  │       │  Azure AI Foundry  │  ← Private   │
  │       │  (Private Endpoint)│    endpoint  │
  │       └────────────────────┘              │
  └───────────────────────────────────────────┘
                    VNet (10.0.0.0/16)
```

### Network Layout

| Subnet | CIDR | Purpose |
|--------|------|--------|
| `snet-apim` | `10.0.0.0/24` | APIM Standard v2 (VNet integration) |
| `snet-aca` | `10.0.2.0/23` | Container Apps Environment (internal) |
| `snet-pe` | `10.0.4.0/24` | Private Endpoints (Foundry) |

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

# Deploy infrastructure
azd up

# Register the agent (runs inside the VNet via Container App Job)
az containerapp job start \
  -n $(azd env get-value agentSetupJobName) \
  -g <your-resource-group>
```

### Test the agent

The test script calls the agent through APIM (the only public endpoint) — no direct Foundry access needed:

```bash
APIM_GATEWAY_URL=$(azd env get-value apimGatewayUrl) \
APIM_AGENT_SUBSCRIPTION_KEY=$(azd env get-value apimAgentSubscriptionKey) \
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
│   ├── main.bicep          # Orchestrator (Container Apps, jobs, gateway connection)
│   ├── apim.bicep          # API Management (model gateway + agent API)
│   ├── foundry.bicep       # AI Foundry (account, project, private endpoint)
│   ├── network.bicep       # VNet, subnets, NSGs, Private DNS zones
│   ├── aca-dns.bicep       # Private DNS for internal Container Apps
│   └── main.bicepparam     # Deployment parameters
├── scripts/
│   ├── setup-foundry-agent.sh   # Agent registration (runs in Container App Job)
│   ├── setup-github-deploy.sh   # OIDC setup for GitHub Actions CI/CD
│   └── test-agent.py            # Interactive agent test client (via APIM)
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions deploy pipeline
├── azure.yaml              # azd project configuration
└── README.md
```
