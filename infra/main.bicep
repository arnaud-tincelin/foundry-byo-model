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
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

// ============================================================================
// 1. NETWORKING (VNet, subnets, NSGs, Private DNS)
// ============================================================================

module network 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
  }
}

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

// ============================================================================
// 3. AI FOUNDRY (private, with deployer IP whitelisted)
// ============================================================================

module foundry 'foundry.bicep' = {
  name: 'foundry'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    peSubnetId: network.outputs.snetPeId
    dnsCognitiveServicesId: network.outputs.dnsCognitiveServicesId
    dnsOpenAiId: network.outputs.dnsOpenAiId
    dnsAiServicesId: network.outputs.dnsAiServicesId
  }
}

// Grant the container apps managed identity Cognitive Services User on Foundry
resource cogServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryRef.id, containerAppsIdentity.id, cognitiveServicesUserRoleId)
  scope: foundryRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reference to the deployed Foundry account (for scoped role assignments)
resource foundryRef 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: 'foundry-${resourceToken}'

  resource project 'projects' existing = {
    name: 'project-${resourceToken}'
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
    vnetConfiguration: {
      infrastructureSubnetId: network.outputs.snetAcaId
      internal: true
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

// Private DNS zone for internal Container Apps environment
module acaDns 'aca-dns.bicep' = {
  name: 'aca-dns'
  params: {
    defaultDomain: containerAppsEnv.properties.defaultDomain
    staticIp: containerAppsEnv.properties.staticIp
    vnetId: network.outputs.vnetId
    tags: tags
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
// AGENT SETUP JOB (runs inside VNet to register agent in Foundry)
// Trigger manually: az containerapp job start -n <job-name> -g <rg>
// ============================================================================

var setupScript = loadTextContent('../scripts/setup-foundry-agent.sh')

resource agentSetupJob 'Microsoft.App/jobs@2024-10-02-preview' = {
  name: 'job-agent-setup-${resourceToken}'
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
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 300
      replicaRetryLimit: 0
    }
    template: {
      containers: [
        {
          name: 'agent-setup'
          image: 'python:3.13-slim'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          command: [ 'sh', '-c', setupScript ]
          env: [
            { name: 'AI_SERVICES_ENDPOINT', value: foundry.outputs.foundryEndpoint }
            { name: 'FOUNDRY_PROJECT_NAME', value: foundry.outputs.projectName }
            { name: 'GATEWAY_CONNECTION_NAME', value: 'custom-model-gateway' }
            { name: 'GATEWAY_MODEL_NAME', value: gatewayModelName }
            { name: 'AZURE_CLIENT_ID', value: containerAppsIdentity.properties.clientId }
          ]
        }
      ]
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
    apimSubnetId: network.outputs.snetApimId
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryId: foundry.outputs.foundryId
    foundryProjectName: foundry.outputs.projectName
  }
}

// ============================================================================
// 9. MODEL GATEWAY CONNECTION (register APIM as model gateway in Foundry)
// ============================================================================

// Note: we use a static list of models in this example
// but it is also possible to have a dynamic list (requires GET /models endpoint on APIM)
resource modelGatewayConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  name: 'custom-model-gateway'
  parent: foundryRef::project
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
output foundryEndpoint string = foundry.outputs.foundryEndpoint
output foundryName string = foundry.outputs.foundryName
output foundryProjectName string = foundry.outputs.projectName

// Container Apps
output modelAppFqdn string = modelApp.properties.configuration.ingress.fqdn

// APIM
output apimGatewayUrl string = apim.outputs.gatewayUrl
#disable-next-line outputs-should-not-contain-secrets
output apimSubscriptionKey string = apim.outputs.subscriptionPrimaryKey
#disable-next-line outputs-should-not-contain-secrets
output apimAgentSubscriptionKey string = apim.outputs.agentSubscriptionKey

// Model Gateway Connection
output gatewayConnectionName string = modelGatewayConnection.name
output gatewayModelName string = gatewayModelName

// Observability
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString

// Identity
output managedIdentityClientId string = containerAppsIdentity.properties.clientId

// Agent Setup Job
output agentSetupJobName string = agentSetupJob.name
