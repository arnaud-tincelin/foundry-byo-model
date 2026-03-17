# Foundry BYO Model

**Bring Your Own Model** to [Microsoft Foundry](https://learn.microsoft.com/azure/ai-studio/) — serve any LLM and wire it into Foundry as a first-class [model gateway](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/ai-gateway), ready for agents.

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
  │       │  Microsoft Foundry │  ← Private   │
  │       │  (Private Endpoint)│    endpoint  │
  │       └────────────────────┘              │
  └───────────────────────────────────────────┘
                    VNet (10.0.0.0/16)
```

## Deployment

⚠️ Because the Foundry project is private, the configuration of the agent is done from a Container App Job within the VNet. This is a "hack" to avoid deploying a jumpbox or a VPN. The job is triggered automatically after provisioning via an `azd` postprovision hook.

You can check the log of the job to verify if the agent was created successfuly from the Azure portal. If so, you should see a similar log:

> Agent created: guess-my-number v4 model=custom-model-gateway/my-custom-model

### Prerequisites

Recommended: open in the provided **Dev Container** which includes all tools

Or, install the following tools locally:

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- An Azure subscription with GPU quota

### Quick Start

```bash
# Log in
azd auth login

# Deploy infrastructure
azd up
```

### Test the agent

The test script calls the agent through APIM (the only public endpoint) — no direct Foundry access needed:

```bash
APIM_GATEWAY_URL=$(azd env get-value apimGatewayUrl) \
APIM_AGENT_SUBSCRIPTION_KEY=$(azd env get-value apimAgentSubscriptionKey) \
uv run scripts/test-agent.py
```

## Optional: CI/CD with GitHub Actions

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
