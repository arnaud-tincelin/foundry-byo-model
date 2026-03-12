"""Post-deployment script to register the custom model and agent in Azure AI Foundry.

Run after deploying the infrastructure with `azd up`.

Prerequisites:
    pip install azure-identity azure-ai-projects

Usage:
    export AI_SERVICES_ENDPOINT="https://<your-ai-services>.cognitiveservices.azure.com/"
    export MODEL_ENDPOINT="https://<model-app-fqdn>"
    python scripts/setup-foundry-agent.py
"""

import os
import sys

try:
    from azure.identity import DefaultAzureCredential
    from azure.ai.projects import AIProjectClient
except ImportError:
    print("Install required packages: pip install azure-identity azure-ai-projects")
    sys.exit(1)


def main():
    endpoint = os.environ.get("AI_SERVICES_ENDPOINT")
    if not endpoint:
        print("Set AI_SERVICES_ENDPOINT environment variable.")
        sys.exit(1)

    credential = DefaultAzureCredential()
    client = AIProjectClient(endpoint=endpoint, credential=credential)

    # Create the guess-my-number agent
    agent = client.agents.create_agent(
        model="custom-model",
        name="Guess My Number",
        instructions=(
            "You are a fun game host for 'Guess My Number'. "
            "Pick a random number between 0 and 100 and have the player guess it. "
            "Give hints like 'higher' or 'lower' after each guess. "
            "Be encouraging and fun!"
        ),
    )

    print(f"Agent created successfully!")
    print(f"  ID:   {agent.id}")
    print(f"  Name: {agent.name}")


if __name__ == "__main__":
    main()
