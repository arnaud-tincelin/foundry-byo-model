@description('Azure region for the APIM resource.')
param location string

@description('Tags to apply to all resources.')
param tags object

@description('Unique token for resource naming.')
param resourceToken string

@description('Publisher email for APIM.')
param apimPublisherEmail string

@description('FQDN of the vLLM model container app.')
param modelAppFqdn string

// ============================================================================
// API MANAGEMENT (Internet-facing gateway)
// ============================================================================

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: 'apim-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: 'Foundry BYO Model'
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

// APIM subscription for the API
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
// OUTPUTS
// ============================================================================

output gatewayUrl string = apim.properties.gatewayUrl

@secure()
output subscriptionPrimaryKey string = apimSubscription.listSecrets().primaryKey
