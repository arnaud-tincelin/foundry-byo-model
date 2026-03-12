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

resource apimApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'model-gateway'
  properties: {
    displayName: 'Model Gateway'
    description: 'OpenAI-compatible model gateway backed by custom vLLM model'
    path: 'openai'
    protocols: [ 'https' ]
    serviceUrl: 'https://${modelApp.properties.configuration.ingress.fqdn}'
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
  }
}

// API-level policy to rewrite model name and cap max_tokens for all chat requests
resource apimApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: apimApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><choose><when condition="@(context.Request.Method == &quot;POST&quot;)"><set-body>@{var body = context.Request.Body.As&lt;JObject&gt;(); body["model"] = "${modelName}"; if(body["max_tokens"] == null || (int)body["max_tokens"] &gt; 512) { body["max_tokens"] = 512; } return body.ToString();}</set-body></when></choose></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

resource apimChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    description: 'Send a chat completion request to the model'
    method: 'POST'
    urlTemplate: '/deployments/{deploymentName}/chat/completions'
    templateParameters: [
      {
        name: 'deploymentName'
        type: 'string'
        required: true
      }
    ]
  }
}

resource apimListDeployments 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'list-deployments'
  properties: {
    displayName: 'List Deployments'
    description: 'List available model deployments'
    method: 'GET'
    urlTemplate: '/deployments'
  }
}

resource apimGetDeployment 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'get-deployment'
  properties: {
    displayName: 'Get Deployment'
    description: 'Get a specific model deployment'
    method: 'GET'
    urlTemplate: '/deployments/{deploymentName}'
    templateParameters: [
      {
        name: 'deploymentName'
        type: 'string'
        required: true
      }
    ]
  }
}

resource apimHealthOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'health'
  properties: {
    displayName: 'Health Check'
    method: 'GET'
    urlTemplate: '/health'
  }
}

// APIM policies: rewrite deployment paths to the vLLM backend
resource apimChatPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimChatOperation
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><rewrite-uri template="/v1/chat/completions" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

resource apimListDeploymentsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimListDeployments
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"data": [{"id": "${gatewayModelName}", "object": "deployment", "model": "${gatewayModelName}"}]}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

resource apimGetDeploymentPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: apimGetDeployment
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"id": "${gatewayModelName}", "object": "deployment", "model": "${gatewayModelName}"}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
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
