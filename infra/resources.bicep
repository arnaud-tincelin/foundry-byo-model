// ---------------------------------------------------------------------------
// Foundry BYO Model - Resource Group Scoped Resources
//
// Leverages patterns and API versions from Azure/AI-Landing-Zones:
//   https://github.com/Azure/AI-Landing-Zones
//
// Deploys:
//   1. AI Foundry v2 (AI Services account + project)
//   2. Container Apps Environment with GPU workload profile
//   3. Model Container App (vLLM serving an open-source model on GPU)
//   4. Agent Container App (Guess My Number game)
//   5. Azure API Management (internet-facing gateway)
//   6. Supporting resources (Log Analytics, ACR, Managed Identity)
// ---------------------------------------------------------------------------

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Location for all resources.')
param location string

@description('Base name seed for resource naming.')
param baseName string

@description('The open-source model to serve on the GPU container (HuggingFace model ID).')
param modelName string = 'microsoft/Phi-4-mini-instruct'

@description('GPU workload profile type for the model container app.')
param gpuWorkloadProfileType string = 'NC24-A100'

@description('Publisher email for APIM.')
param apimPublisherEmail string

@description('Tags to apply to all resources.')
param tags object = {}

@description('The name of the azd service for the agent container app.')
param agentServiceName string = 'agent'

// ============================================================================
// VARIABLES
// ============================================================================

var aiServicesName = 'ais-${baseName}'
var projectName = 'project-${baseName}'
var logAnalyticsName = 'law-${baseName}'
var appInsightsName = 'appi-${baseName}'
var containerRegistryName = toLower(replace('acr${baseName}', '-', ''))
var containerEnvName = 'cae-${baseName}'
var modelAppName = 'ca-model-${baseName}'
var agentAppName = 'ca-agent-${baseName}'
var apimName = 'apim-${baseName}'
var identityName = 'id-${baseName}'

// RBAC Role Definition IDs
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

// ============================================================================
// 1. OBSERVABILITY
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ============================================================================
// 2. MANAGED IDENTITY
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// ============================================================================
// 3. CONTAINER REGISTRY
// ============================================================================

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// Grant the managed identity AcrPull on the registry
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, managedIdentity.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 4. AI FOUNDRY v2 (following AI-Landing-Zones patterns)
//    API version: 2025-04-01-preview (same as AILZ)
// ============================================================================

resource aiServicesAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiServicesName
  location: location
  tags: tags
  sku: { name: 'S0' }
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: aiServicesName
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

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: aiServicesAccount
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    description: 'Foundry BYO Model project with custom agent'
    displayName: 'Guess My Number Agent Project'
  }
}

// Grant the managed identity Cognitive Services User on AI Services
resource cogServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesAccount.id, managedIdentity.id, cognitiveServicesUserRoleId)
  scope: aiServicesAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 5. CONTAINER APPS ENVIRONMENT
//    Uses AVM-aligned configuration (same as AI-Landing-Zones wrappers)
// ============================================================================

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: containerEnvName
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
        minimumCount: 0
        maximumCount: 1
      }
    ]
    zoneRedundant: false
  }
}

// ============================================================================
// 6. MODEL CONTAINER APP (vLLM on GPU)
// ============================================================================

resource modelApp 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: modelAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnv.id
    workloadProfileName: 'gpu'
    configuration: {
      ingress: {
        external: false
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
            cpu: json('6')
            memory: '12Gi'
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
// 7. AGENT CONTAINER APP (Guess My Number)
// ============================================================================

resource agentApp 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: agentAppName
  location: location
  tags: union(tags, { 'azd-service-name': agentServiceName })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'agent'
          // Placeholder image — replaced by `azd deploy` with the built agent image
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'MODEL_ENDPOINT'
              value: 'https://${modelApp.properties.configuration.ingress.fqdn}'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
  dependsOn: [
    acrPullAssignment
  ]
}

// ============================================================================
// 8. API MANAGEMENT (Internet-facing gateway)
// ============================================================================

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
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
  name: 'guess-number-agent'
  properties: {
    displayName: 'Guess My Number Agent'
    description: 'AI-powered number guessing game agent exposed via Azure AI Foundry'
    path: 'agent'
    protocols: [ 'https' ]
    serviceUrl: 'https://${agentApp.properties.configuration.ingress.fqdn}'
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
  }
}

resource apimChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: apimApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    description: 'Send a message to the guess-my-number agent'
    method: 'POST'
    urlTemplate: '/v1/chat/completions'
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

// ============================================================================
// OUTPUTS
// ============================================================================

// AI Foundry
output aiServicesEndpoint string = aiServicesAccount.properties.endpoint
output aiServicesName string = aiServicesAccount.name
output projectName string = aiProject.name

// Container Apps
output modelAppFqdn string = modelApp.properties.configuration.ingress.fqdn
output agentAppFqdn string = agentApp.properties.configuration.ingress.fqdn
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerRegistryName string = containerRegistry.name

// APIM
output apimGatewayUrl string = apim.properties.gatewayUrl

// Observability
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString

// Identity
output managedIdentityClientId string = managedIdentity.properties.clientId

// azd
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.name
