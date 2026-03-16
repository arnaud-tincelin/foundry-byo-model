@description('Azure region for the APIM resource.')
param location string

@description('Tags to apply to all resources.')
param tags object

@description('Unique token for resource naming.')
param resourceToken string

@description('Publisher email for APIM.')
param apimPublisherEmail string

@description('FQDN of the vLLM model container app (internal).')
param modelAppFqdn string

@description('Subnet resource ID for APIM VNet integration.')
param apimSubnetId string

@description('Foundry endpoint URL (for agent API backend).')
param foundryEndpoint string

@description('Foundry resource ID (for RBAC).')
param foundryId string

@description('Foundry project name (for project-scoped agent API).')
param foundryProjectName string

// RBAC Role Definition IDs
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

// ============================================================================
// API MANAGEMENT (Internet-facing gateway with VNet integration)
// ============================================================================

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: 'apim-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: 'Foundry BYO Model'
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
  }
}

// Grant APIM managed identity Cognitive Services User on Foundry
resource foundryRef 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: last(split(foundryId, '/'))
}

resource apimCogServicesRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryId, apim.id, cognitiveServicesUserRoleId)
  scope: foundryRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// APIM backend pointing to the vLLM model container app (with /v1 base path)
resource apimBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'vllm-backend'
  properties: {
    description: 'vLLM model backend'
    url: 'https://${modelAppFqdn}/v1'
    protocol: 'http'
  }
}

// Azure OpenAI compatible API with wildcard operations that rewrite paths to vLLM format
// Foundry sends: /openai/deployments/{name}/chat/completions → vLLM expects: /v1/chat/completions
resource apimApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'model-gateway'
  properties: {
    displayName: 'Model Gateway API'
    path: 'openai'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
  }
}

// Operation: POST /deployments/{deployment-id}/chat/completions → /v1/chat/completions
resource apimOpChatCompletions 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

resource apimOpChatCompletionsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimOpChatCompletions
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><rewrite-uri template="/chat/completions" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Operation: POST /deployments/{deployment-id}/completions → /v1/completions
resource apimOpCompletions 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'completions'
  properties: {
    displayName: 'Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

resource apimOpCompletionsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimOpCompletions
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><rewrite-uri template="/completions" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// // Operation: GET /models → /v1/models (direct, no deployment prefix)
// resource apimOpModelsRoot 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
//   parent: apimApi
//   name: 'list-models-root'
//   properties: {
//     displayName: 'List Models (root)'
//     method: 'GET'
//     urlTemplate: '/models'
//   }
// }

// resource apimOpModelsRootPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
//   parent: apimOpModelsRoot
//   name: 'policy'
//   properties: {
//     format: 'xml'
//     value: '<policies><inbound><base /><rewrite-uri template="/models" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
//   }
// }

// API-level policy: set backend, strip api-version, cap max_tokens
resource apimApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: apimApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><set-backend-service backend-id="${apimBackend.name}" /><set-query-parameter name="api-version" exists-action="delete" /><choose><when condition="@(context.Request.Method == &quot;POST&quot;)"><set-body>@{var body = context.Request.Body.As&lt;JObject&gt;(); if(body["max_tokens"] == null || (int)body["max_tokens"] &gt; 512) { body["max_tokens"] = 512; } return body.ToString();}</set-body></when></choose></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// APIM subscription for the model gateway API
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'model-gateway-sub'
  properties: {
    scope: apimApi.id
    displayName: 'Model Gateway Subscription'
    state: 'active'
  }
}

// ============================================================================
// AGENT API (proxies Foundry Responses API via APIM)
// ============================================================================

// Backend pointing to Foundry (accessed via private endpoint from VNet)
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'foundry-backend'
  properties: {
    description: 'Azure AI Foundry backend (project-scoped)'
    url: '${foundryEndpoint}api/projects/${foundryProjectName}/openai/v1'
    protocol: 'http'
  }
}

resource agentApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'agent-api'
  properties: {
    displayName: 'Agent API'
    path: 'agent'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
  }
}

// POST /responses → Foundry POST /openai/responses
resource agentOpResponses 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: agentApi
  name: 'create-response'
  properties: {
    displayName: 'Create Response'
    method: 'POST'
    urlTemplate: '/responses'
  }
}

// GET /responses/{response-id} → Foundry GET /openai/responses/{response-id}
resource agentOpGetResponse 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: agentApi
  name: 'get-response'
  properties: {
    displayName: 'Get Response'
    method: 'GET'
    urlTemplate: '/responses/{response-id}'
    templateParameters: [
      {
        name: 'response-id'
        required: true
        type: 'string'
      }
    ]
  }
}

// API-level policy: route to Foundry backend with managed identity auth
resource agentApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: agentApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><set-backend-service backend-id="${foundryBackend.name}" /><authentication-managed-identity resource="https://ai.azure.com" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Subscription for the agent API
resource agentSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'agent-api-sub'
  properties: {
    scope: agentApi.id
    displayName: 'Agent API Subscription'
    state: 'active'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output gatewayUrl string = apim.properties.gatewayUrl

@secure()
output subscriptionPrimaryKey string = apimSubscription.listSecrets().primaryKey

@secure()
output agentSubscriptionKey string = agentSubscription.listSecrets().primaryKey
