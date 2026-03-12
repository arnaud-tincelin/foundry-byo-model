targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources but AI Foundry.')
param location string

@description('The open-source model to serve on the GPU container (HuggingFace model ID).')
param modelName string = 'microsoft/Phi-4-mini-instruct'

@description('GPU workload profile type for the model container app.')
param gpuWorkloadProfileType string = 'Consumption-GPU-NC8as-T4'

@description('Publisher email for APIM.')
param apimPublisherEmail string

@description('Name for the model gateway connection in Foundry.')
param gatewayConnectionName string = 'custom-model-gateway'

@description('The model name exposed through the gateway (used as deployment name).')
param gatewayModelName string = 'custom-model'

// ============================================================================
// VARIABLES
// ============================================================================

#disable-next-line no-unused-vars
var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))

var tags = {
  'azd-env-name': environmentName
}

// RBAC Role Definition IDs
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource containerAppsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ca-${resourceToken}'
  location: location
  tags: tags
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: toLower(replace('acr${resourceToken}', '-', ''))
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// Grant the managed identity AcrPull on the registry
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, containerAppsIdentity.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 4. AI FOUNDRY v2 (following AI-Landing-Zones patterns)
//    API version: 2025-04-01-preview (same as AILZ)
// ============================================================================

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: 'foundry-${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'S0' }
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: 'foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    disableLocalAuth: false
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: foundry
  name: 'project-${resourceToken}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    description: 'Foundry BYO Model project with custom agent'
    displayName: 'Guess My Number Agent Project'
  }
}

// Grant the managed identity Cognitive Services User on AI Services
resource cogServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, containerAppsIdentity.id, cognitiveServicesUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: 'cae-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        workloadProfileType: 'Consumption'
        name: 'Consumption'
      }
      {
        workloadProfileType: gpuWorkloadProfileType
        name: 'gpu'
      }
    ]
    zoneRedundant: false
  }
}

resource modelApp 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: 'ca-model-${resourceToken}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerAppsIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnv.id
    workloadProfileName: 'gpu'
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'vllm'
          image: 'vllm/vllm-openai:latest'
          resources: {
            cpu: json('8')
            memory: '56Gi'
            gpu: 1
          }
          command: [
            'python3'
            '-m'
            'vllm.entrypoints.openai.api_server'
          ]
          args: [
            '--model'
            modelName
            '--served-model-name'
            gatewayModelName
            '--port'
            '8000'
            '--trust-remote-code'
            '--max-model-len'
            '16384'
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ============================================================================
// 8. API MANAGEMENT (Internet-facing gateway)
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
    url: 'https://${modelApp.properties.configuration.ingress.fqdn}/v1'
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

// Operation: GET /deployments/{deployment-id}/models → /v1/models
resource apimOpModels 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'list-models'
  properties: {
    displayName: 'List Models'
    method: 'GET'
    urlTemplate: '/deployments/{deployment-id}/models'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

resource apimOpModelsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimOpModels
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><rewrite-uri template="/models" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
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

// Operation: GET /models → /v1/models (direct, no deployment prefix)
resource apimOpModelsRoot 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'list-models-root'
  properties: {
    displayName: 'List Models (root)'
    method: 'GET'
    urlTemplate: '/models'
  }
}

resource apimOpModelsRootPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimOpModelsRoot
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><rewrite-uri template="/models" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

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
// 9. MODEL GATEWAY CONNECTION (register APIM as model gateway in Foundry)
// ============================================================================

resource modelGatewayConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  name: gatewayConnectionName
  parent: foundryProject
  properties: {
    category: 'ModelGateway'
    target: '${apim.properties.gatewayUrl}/openai'
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: apimSubscription.listSecrets().primaryKey
    }
    metadata: {
      deploymentInPath: 'true'
      inferenceAPIVersion: ''
      models: string([
        {
          name: gatewayModelName
          properties: {
            model: {
              name: gatewayModelName
              version: '1'
              format: 'OpenAI'
            }
          }
        }
      ])
    }
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

// AI Foundry
output foundryEndpoint string = foundry.properties.endpoint
output foundryName string = foundry.name
output foundryProjectName string = foundryProject.name

// Container Apps
output modelAppFqdn string = modelApp.properties.configuration.ingress.fqdn
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerRegistryName string = containerRegistry.name

// APIM
output apimGatewayUrl string = apim.properties.gatewayUrl

// Model Gateway Connection
output gatewayConnectionName string = modelGatewayConnection.name
output gatewayModelName string = gatewayModelName

// Observability
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString

// Identity
output managedIdentityClientId string = containerAppsIdentity.properties.clientId

// azd
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.name
