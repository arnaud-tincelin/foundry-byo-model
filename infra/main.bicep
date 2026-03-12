// ---------------------------------------------------------------------------
// Foundry BYO Model - Subscription-level Orchestrator
//
// Creates a resource group and delegates all resource provisioning
// to the resources.bicep module.  This allows `azd up --no-prompt`
// to work without pre-selecting a resource group.
// ---------------------------------------------------------------------------

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Location for all resources.')
param location string

@description('Name of the resource group to create / use.')
param resourceGroupName string = ''

@description('Base name seed for resource naming. Auto-generated if not provided.')
param baseName string = ''

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

var actualResourceGroupName = !empty(resourceGroupName)
  ? resourceGroupName
  : 'rg-foundry-byo-model-${location}'
var actualBaseName = !empty(baseName)
  ? baseName
  : toLower(substring(uniqueString(subscription().id, actualResourceGroupName, location), 0, 8))

// ============================================================================
// RESOURCE GROUP
// ============================================================================

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: actualResourceGroupName
  location: location
  tags: tags
}

// ============================================================================
// ALL RESOURCES (delegated to module)
// ============================================================================

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    baseName: actualBaseName
    modelName: modelName
    gpuWorkloadProfileType: gpuWorkloadProfileType
    apimPublisherEmail: apimPublisherEmail
    tags: tags
    agentServiceName: agentServiceName
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

// AI Foundry
output aiServicesEndpoint string = resources.outputs.aiServicesEndpoint
output aiServicesName string = resources.outputs.aiServicesName
output projectName string = resources.outputs.projectName

// Container Apps
output modelAppFqdn string = resources.outputs.modelAppFqdn
output agentAppFqdn string = resources.outputs.agentAppFqdn
output containerRegistryLoginServer string = resources.outputs.containerRegistryLoginServer
output containerRegistryName string = resources.outputs.containerRegistryName

// APIM
output apimGatewayUrl string = resources.outputs.apimGatewayUrl

// Observability
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId
output appInsightsConnectionString string = resources.outputs.appInsightsConnectionString

// Identity
output managedIdentityClientId string = resources.outputs.managedIdentityClientId

// azd
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.AZURE_CONTAINER_REGISTRY_NAME
