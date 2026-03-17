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

// ============================================================================
// 2. AI FOUNDRY (private, with deployer IP whitelisted)
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

// ============================================================================
// 3. CONTAINER APPS (Log Analytics, App Insights, Identity, Environment, Apps)
// ============================================================================

module aca 'aca.bicep' = {
  name: 'aca'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    snetAcaId: network.outputs.snetAcaId
    gatewayModelName: gatewayModelName
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryProjectName: foundry.outputs.projectName
    foundryResourceName: foundry.outputs.foundryName
  }
}

// Private DNS zone for internal Container Apps environment
module acaDns 'aca-dns.bicep' = {
  name: 'aca-dns'
  params: {
    defaultDomain: aca.outputs.containerAppsEnvDefaultDomain
    staticIp: aca.outputs.containerAppsEnvStaticIp
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

// ============================================================================
// 4. API MANAGEMENT (Internet-facing gateway)
// ============================================================================

module apim 'apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    apimPublisherEmail: apimPublisherEmail
    modelAppFqdn: aca.outputs.modelAppFqdn
    apimSubnetId: network.outputs.snetApimId
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryResourceName: foundry.outputs.foundryName
    foundryProjectName: foundry.outputs.projectName
    gatewayModelName: gatewayModelName
  }
}

// AI Foundry
output foundryEndpoint string = foundry.outputs.foundryEndpoint
output foundryName string = foundry.outputs.foundryName
output foundryProjectName string = foundry.outputs.projectName

// Container Apps
output modelAppFqdn string = aca.outputs.modelAppFqdn

// APIM
output apimGatewayUrl string = apim.outputs.gatewayUrl
#disable-next-line outputs-should-not-contain-secrets
output apimSubscriptionKey string = apim.outputs.subscriptionPrimaryKey
#disable-next-line outputs-should-not-contain-secrets
output apimAgentSubscriptionKey string = apim.outputs.agentSubscriptionKey

// Model Gateway Connection
output gatewayConnectionName string = apim.outputs.gatewayConnectionName
output gatewayModelName string = gatewayModelName

// Observability
output logAnalyticsWorkspaceId string = aca.outputs.logAnalyticsWorkspaceId
output appInsightsConnectionString string = aca.outputs.appInsightsConnectionString

// Identity
output managedIdentityClientId string = aca.outputs.managedIdentityClientId

// Agent Setup Job
output agentSetupJobName string = aca.outputs.agentSetupJobName
