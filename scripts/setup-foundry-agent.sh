#!/bin/sh
set -e

pip install -q azure-identity azure-ai-projects

python3 -c "
import os
from azure.identity import ManagedIdentityCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition

endpoint = os.environ['AI_SERVICES_ENDPOINT']
project = os.environ['FOUNDRY_PROJECT_NAME']
conn = os.environ['GATEWAY_CONNECTION_NAME']
model = os.environ['GATEWAY_MODEL_NAME']
client_id = os.environ['AZURE_CLIENT_ID']

project_endpoint = f'{endpoint.rstrip(chr(47))}/api/projects/{project}'
model_name = f'{conn}/{model}'

cred = ManagedIdentityCredential(client_id=client_id)
client = AIProjectClient(endpoint=project_endpoint, credential=cred)

definition = PromptAgentDefinition(
    model=model_name,
    instructions='You are a fun game host for Guess My Number. Pick a random number between 0 and 100 and have the player guess it. Give hints like higher or lower after each guess. Be encouraging and fun!',
)
agent = client.agents.create_version(
    agent_name='guess-my-number',
    definition=definition,
    description='Guess My Number game host agent backed by a custom model via gateway',
)
print(f'Agent created: {agent.name} v{agent.version} model={model_name}')
"
