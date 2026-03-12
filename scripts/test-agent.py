#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "azure-identity",
#     "azure-ai-projects",
#     "openai",
# ]
# ///
"""Interactive conversation with the Guess My Number agent via Foundry Responses API.

Usage:
    export AI_SERVICES_ENDPOINT="https://<your-ai-services>.cognitiveservices.azure.com/"
    export FOUNDRY_PROJECT_NAME="<project-name>"
    export GATEWAY_CONNECTION_NAME="custom-model-gateway"
    export GATEWAY_MODEL_NAME="custom-model"
    uv run scripts/test-agent.py
"""

import os
import sys

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

AGENT_NAME = "guess-my-number"


def main():
    endpoint = os.environ.get("AI_SERVICES_ENDPOINT")
    if not endpoint:
        print("Set AI_SERVICES_ENDPOINT environment variable.")
        sys.exit(1)

    project_name = os.environ.get("FOUNDRY_PROJECT_NAME")
    if not project_name:
        print("Set FOUNDRY_PROJECT_NAME environment variable.")
        sys.exit(1)

    project_endpoint = f"{endpoint.rstrip('/')}/api/projects/{project_name}"

    gateway_connection = os.environ.get("GATEWAY_CONNECTION_NAME", "custom-model-gateway")
    gateway_model = os.environ.get("GATEWAY_MODEL_NAME", "custom-model")
    agent_model = f"{gateway_connection}/{gateway_model}"

    credential = DefaultAzureCredential()
    project_client = AIProjectClient(endpoint=project_endpoint, credential=credential)
    openai_client = project_client.get_openai_client()

    agent_ref = {"agent_reference": {"name": AGENT_NAME, "type": "agent_reference"}}

    print("🎮 Guess My Number — Chat with the agent (type 'quit' to exit)\n")

    previous_id = None
    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye!")
            break

        if not user_input or user_input.lower() in ("quit", "exit", "q"):
            print("Bye!")
            break

        kwargs = {
            "model": agent_model,
            "input": user_input,
            "store": True,
            "extra_body": agent_ref,
        }
        if previous_id:
            kwargs["previous_response_id"] = previous_id

        response = openai_client.responses.create(**kwargs)
        previous_id = response.id
        print(f"Agent: {response.output_text}\n")


if __name__ == "__main__":
    main()
