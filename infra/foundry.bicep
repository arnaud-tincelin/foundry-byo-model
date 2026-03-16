@description('Azure region.')
param location string

@description('Tags to apply to all resources.')
param tags object

@description('Unique token for resource naming.')
param resourceToken string

@description('Subnet resource ID for private endpoints.')
param peSubnetId string

@description('Private DNS zone ID for Cognitive Services.')
param dnsCognitiveServicesId string

@description('Private DNS zone ID for OpenAI.')
param dnsOpenAiId string

@description('Private DNS zone ID for AI Services.')
param dnsAiServicesId string

// ============================================================================
// AI FOUNDRY (AI Services account + project)
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
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
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

// ============================================================================
// PRIVATE ENDPOINT
// ============================================================================

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-foundry-${resourceToken}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'foundry-connection'
        properties: {
          privateLinkServiceId: foundry.id
          groupIds: [ 'account' ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'foundry-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cogservices-dns-config'
        properties: {
          privateDnsZoneId: dnsCognitiveServicesId
        }
      }
      {
        name: 'openai-dns-config'
        properties: {
          privateDnsZoneId: dnsOpenAiId
        }
      }
      {
        name: 'aiservices-dns-config'
        properties: {
          privateDnsZoneId: dnsAiServicesId
        }
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output foundryId string = foundry.id
output foundryEndpoint string = foundry.properties.endpoint
output foundryName string = foundry.name
output projectName string = foundry::project.name
