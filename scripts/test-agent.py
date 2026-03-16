#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "openai",
# ]
# ///
"""Interactive conversation with the Guess My Number agent via APIM gateway.

The agent API is exposed through APIM, which proxies requests to Foundry
using managed identity authentication. No Azure credentials needed — just
the APIM subscription key.

Usage:
    export APIM_GATEWAY_URL="https://<your-apim>.azure-api.net"
    export APIM_AGENT_SUBSCRIPTION_KEY="<key>"
    export GATEWAY_CONNECTION_NAME="custom-model-gateway"
    export GATEWAY_MODEL_NAME="my-custom-model"
    uv run scripts/test-agent.py
"""

import os
import sys

from openai import OpenAI

AGENT_NAME = "guess-my-number"


def main():
    gateway_url = os.environ.get("APIM_GATEWAY_URL")
    if not gateway_url:
        print("Set APIM_GATEWAY_URL environment variable.")
        sys.exit(1)

    api_key = os.environ.get("APIM_AGENT_SUBSCRIPTION_KEY")
    if not api_key:
        print("Set APIM_AGENT_SUBSCRIPTION_KEY environment variable.")
        sys.exit(1)

    gateway_connection = os.environ.get("GATEWAY_CONNECTION_NAME", "custom-model-gateway")
    gateway_model = os.environ.get("GATEWAY_MODEL_NAME", "my-custom-model")
    agent_model = f"{gateway_connection}/{gateway_model}"

    # Point OpenAI client at the APIM agent API endpoint
    client = OpenAI(
        base_url=f"{gateway_url.rstrip('/')}/agent",
        api_key=api_key,
        default_headers={"api-key": api_key},
    )

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

        response = client.responses.create(**kwargs)
        previous_id = response.id
        print(f"Agent: {response.output_text}\n")


if __name__ == "__main__":
    main()
