#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "azure-identity",
#     "azure-ai-projects",
# ]
# ///
"""Post-deployment script to register a prompt agent in Azure AI Foundry.

The agent uses a custom model exposed through a model gateway (APIM).
The model gateway connection is created by the Bicep infrastructure.

Usage:
    export AI_SERVICES_ENDPOINT="https://<your-ai-services>.cognitiveservices.azure.com/"
    export FOUNDRY_PROJECT_NAME="<project-name>"
    export GATEWAY_CONNECTION_NAME="<connection-name>"
    export GATEWAY_MODEL_NAME="<model-name>"
    uv run scripts/setup-foundry-agent.py
"""

import os
import sys

try:
    from azure.identity import DefaultAzureCredential
    from azure.ai.projects import AIProjectClient
    from azure.ai.projects.models import PromptAgentDefinition
except ImportError:
    print("Install required packages: pip install azure-identity azure-ai-projects")
    sys.exit(1)


def main():
    endpoint = os.environ.get("AI_SERVICES_ENDPOINT")
    if not endpoint:
        print("Set AI_SERVICES_ENDPOINT environment variable.")
        sys.exit(1)

    project_name = os.environ.get("FOUNDRY_PROJECT_NAME")
    if not project_name:
        print("Set FOUNDRY_PROJECT_NAME environment variable.")
        sys.exit(1)

    connection_name = os.environ.get("GATEWAY_CONNECTION_NAME")
    if not connection_name:
        print("Set GATEWAY_CONNECTION_NAME environment variable.")
        sys.exit(1)

    model_name = os.environ.get("GATEWAY_MODEL_NAME")
    if not model_name:
        print("Set GATEWAY_MODEL_NAME environment variable.")
        sys.exit(1)

    # Build the project-scoped endpoint
    project_endpoint = f"{endpoint.rstrip('/')}/api/projects/{project_name}"

    # Model deployment name format: <connection-name>/<model-name>
    model_deployment_name = f"{connection_name}/{model_name}"

    credential = DefaultAzureCredential()
    client = AIProjectClient(endpoint=project_endpoint, credential=credential)

    # Create a prompt agent that routes through the model gateway
    definition = PromptAgentDefinition(
        model=model_deployment_name,
        instructions=(
            "You are a fun game host for 'Guess My Number'. "
            "Pick a random number between 0 and 100 and have the player guess it. "
            "Give hints like 'higher' or 'lower' after each guess. "
            "Be encouraging and fun!"
        ),
    )

    agent = client.agents.create_version(
        agent_name="guess-my-number",
        definition=definition,
        description="Guess My Number game host agent backed by a custom model via gateway",
    )

    print(f"Agent created successfully!")
    print(f"  Name:    {agent.name}")
    print(f"  Version: {agent.version}")
    print(f"  Model:   {model_deployment_name}")


if __name__ == "__main__":
    main()
