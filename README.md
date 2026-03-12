# Foundry BYO Model

Deploy a private [Azure AI Foundry v2](https://learn.microsoft.com/azure/ai-studio/) with a custom "Guess My Number" agent, powered by an open-source model served on a GPU Container App and exposed through Azure API Management.

Architecture inspired by [Azure/AI-Landing-Zones](https://github.com/Azure/AI-Landing-Zones) (Bicep, `azd`-compatible).

## Architecture

```
Internet
    │
    ▼
┌────────────┐
│   Azure    │
│    APIM    │  ← Public gateway (subscription key)
└─────┬──────┘
      │
      ▼
┌────────────┐      ┌────────────────────┐
│  Agent App │─────▶│   Model App (GPU)  │
│ (Container │      │  vLLM + Phi-4-mini │
│   Apps)    │      │  (internal only)   │
└────────────┘      └────────────────────┘
      │
      ▼
┌─────────────────────┐
│  Azure AI Foundry   │
│  (Account+Project)  │
└─────────────────────┘
```

### Resources deployed

| Resource | Purpose |
|----------|---------|
| **AI Services Account** | Foundry v2 with project management |
| **AI Foundry Project** | Workspace for agents and models |
| **Container Apps Environment** | Hosts both apps (Consumption + GPU profiles) |
| **Model Container App** | vLLM serving `microsoft/Phi-4-mini-instruct` on GPU |
| **Agent Container App** | "Guess My Number" game agent (Python/FastAPI) |
| **API Management** | Internet-facing gateway (Consumption tier) |
| **Container Registry** | Stores the agent container image |
| **Log Analytics + App Insights** | Observability |
| **Managed Identity** | RBAC for ACR pull and Cognitive Services access |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [uv](https://docs.astral.sh/uv/getting-started/installation/) (Python package manager)
- An Azure subscription with GPU quota (e.g., `NC24-A100`)

Or simply open in the provided **Dev Container** which includes all tools.

## Quick Start

```bash
# 1. Log in
azd auth login

# 2. Deploy everything
azd up

# 3. (Optional) Register the agent in Foundry
export AI_SERVICES_ENDPOINT="<from azd output>"
cd scripts && uv run setup-foundry-agent.py
```

## CI/CD Setup (GitHub Actions)

The deploy workflow (`.github/workflows/deploy.yml`) uses OIDC federated credentials. Run the setup script to create the required Azure AD app registration and role assignments:

```bash
# Uses the current Azure CLI subscription
./scripts/setup-github-deploy.sh

# Or specify a subscription explicitly
./scripts/setup-github-deploy.sh --subscription <subscription-id>
```

The script will print the GitHub secrets you need to configure under **Settings → Environments → `production` → Secrets**:

| Secret | Description |
|--------|-------------|
| `AZURE_CLIENT_ID` | App registration client ID (printed by the script) |
| `AZURE_TENANT_ID` | Azure AD tenant ID (printed by the script) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID (printed by the script) |
| `AZURE_LOCATION` | Azure region, e.g. `eastus2` |
| `APIM_PUBLISHER_EMAIL` | Email for API Management publisher |

## Local Development

```bash
cd src/agent

# Install dependencies
uv sync

# Run locally
uv run uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

### Test the agent

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "I guess 50"}],
    "session_id": "test-session"
  }'
```

## Configuration

Edit `infra/main.bicepparam` to customise:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `modelName` | `microsoft/Phi-4-mini-instruct` | HuggingFace model ID for vLLM |
| `gpuWorkloadProfileType` | `NC24-A100` | GPU workload profile |
| `apimPublisherEmail` | `admin@example.com` | APIM publisher email |

## Project Structure

```
├── .devcontainer/          # Dev Container configuration
├── infra/
│   ├── main.bicep          # All Azure resources (Foundry, Container Apps, APIM)
│   └── main.bicepparam     # Deployment parameters
├── src/agent/
│   ├── app.py              # Guess My Number agent (FastAPI)
│   ├── pyproject.toml      # Python project (managed by uv)
│   ├── uv.lock             # Locked dependencies
│   └── Dockerfile          # Container image (uses uv)
├── scripts/
│   ├── setup-github-deploy.sh # OIDC + role setup for GitHub Actions
│   └── setup-foundry-agent.py  # Post-deploy Foundry registration
├── azure.yaml              # azd project configuration
└── README.md
```

## References

- [Azure AI Landing Zones](https://github.com/Azure/AI-Landing-Zones) — Enterprise reference architecture
- [Azure AI Foundry documentation](https://learn.microsoft.com/azure/ai-studio/)
- [vLLM](https://github.com/vllm-project/vllm) — High-throughput LLM serving
- [uv](https://docs.astral.sh/uv/) — Fast Python package manager
