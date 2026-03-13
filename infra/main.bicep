targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources but AI Foundry.')
param location string

@description('Publisher email for APIM.')
param apimPublisherEmail string

// ============================================================================
// VARIABLES
// ============================================================================

@description('The model name exposed through the gateway (used as deployment name).')
var gatewayModelName string = 'my-custom-model'

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

  resource project 'projects' = {
  name: 'project-${resourceToken}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    description: 'Foundry BYO Model project with custom agent'
    displayName: 'Guess My Number Agent Project'
  }
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
        workloadProfileType: 'Consumption-GPU-NC8as-T4'
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
            'microsoft/Phi-4-mini-instruct'
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

module apim 'apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    apimPublisherEmail: apimPublisherEmail
    modelAppFqdn: modelApp.properties.configuration.ingress.fqdn
  }
}

// ============================================================================
// 9. MODEL GATEWAY CONNECTION (register APIM as model gateway in Foundry)
// ============================================================================

// Note: we use a static list of models in this example
// but it is also possible to have a dynamic list (requires GET /models endpoint on APIM)
resource modelGatewayConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  name: 'custom-model-gateway'
  parent: foundry::project
  properties: {
    category: 'ModelGateway'
    target: '${apim.outputs.gatewayUrl}/openai'
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: apim.outputs.subscriptionPrimaryKey
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

// AI Foundry
output foundryEndpoint string = foundry.properties.endpoint
output foundryName string = foundry.name
output foundryProjectName string = foundry::project.name

// Container Apps
output modelAppFqdn string = modelApp.properties.configuration.ingress.fqdn
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerRegistryName string = containerRegistry.name

// APIM
output apimGatewayUrl string = apim.outputs.gatewayUrl

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
