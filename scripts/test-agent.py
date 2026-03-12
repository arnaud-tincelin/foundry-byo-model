#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "azure-identity",
#     "azure-ai-projects",
#     "openai",
# ]
# ///
"""Test the Guess My Number agent by sending messages through the Foundry Responses API.

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

    # Turn 1: greet the agent
    print("--- Sending: 'Hi! Let's play!' ---")
    r1 = openai_client.responses.create(
        model=agent_model,
        input="Hi! Let's play!",
        extra_body=agent_ref,
    )
    print(f"Agent: {r1.output_text}\n")

    # Turn 2: first guess (chain via previous_response_id)
    print("--- Sending: 'Is it 50?' ---")
    r2 = openai_client.responses.create(
        model=agent_model,
        input="Is it 50?",
        previous_response_id=r1.id,
        extra_body=agent_ref,
    )
    print(f"Agent: {r2.output_text}\n")

    # Turn 3: another guess
    print("--- Sending: 'How about 25?' ---")
    r3 = openai_client.responses.create(
        model=agent_model,
        input="How about 25?",
        previous_response_id=r2.id,
        extra_body=agent_ref,
    )
    print(f"Agent: {r3.output_text}")


if __name__ == "__main__":
    main()
