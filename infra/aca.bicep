@description('Azure region for all Container Apps resources.')
param location string

@description('Tags to apply to all resources.')
param tags object

@description('Unique token for resource naming.')
param resourceToken string

@description('Subnet resource ID for the Container Apps environment.')
param snetAcaId string

@description('The model name exposed through the gateway (used as deployment name).')
param gatewayModelName string

@description('Foundry endpoint URL (for agent setup job).')
param foundryEndpoint string

@description('Foundry project name (for agent setup job).')
param foundryProjectName string

@description('Foundry account resource name (for RBAC).')
param foundryResourceName string

// ============================================================================
// OBSERVABILITY
// ============================================================================

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

// ============================================================================
// MANAGED IDENTITY
// ============================================================================

resource containerAppsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ca-${resourceToken}'
  location: location
  tags: tags
}

// Grant the container apps managed identity Cognitive Services User on Foundry
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource foundryRef 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryResourceName
}

resource cogServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryRef.id, containerAppsIdentity.id, cognitiveServicesUserRoleId)
  scope: foundryRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// CONTAINER APPS ENVIRONMENT
// ============================================================================

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
      infrastructureSubnetId: snetAcaId
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

// ============================================================================
// CONTAINER APP - vLLM MODEL SERVER
// ============================================================================

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
            { name: 'AI_SERVICES_ENDPOINT', value: foundryEndpoint }
            { name: 'FOUNDRY_PROJECT_NAME', value: foundryProjectName }
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
// OUTPUTS
// ============================================================================

output containerAppsEnvDefaultDomain string = containerAppsEnv.properties.defaultDomain
output containerAppsEnvStaticIp string = containerAppsEnv.properties.staticIp
output modelAppFqdn string = modelApp.properties.configuration.ingress.fqdn
output managedIdentityClientId string = containerAppsIdentity.properties.clientId
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output agentSetupJobName string = agentSetupJob.name
