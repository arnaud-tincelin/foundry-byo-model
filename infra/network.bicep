@description('Azure region for all networking resources.')
param location string

@description('Tags to apply to all resources.')
param tags object

@description('Unique token for resource naming.')
param resourceToken string

// ============================================================================
// VIRTUAL NETWORK
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'snet-apim'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsgApim.id }
          delegations: [
            {
              name: 'apim-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: '10.0.2.0/23'
          networkSecurityGroup: { id: nsgAca.id }
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '10.0.4.0/24'
          networkSecurityGroup: { id: nsgPe.id }
        }
      }
    ]
  }
}

// ============================================================================
// NETWORK SECURITY GROUPS
// ============================================================================

resource nsgApim 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-apim-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-apim-management'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'allow-https-inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-load-balancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
    ]
  }
}

resource nsgAca 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-aca-${resourceToken}'
  location: location
  tags: tags
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-pe-${resourceToken}'
  location: location
  tags: tags
}

// ============================================================================
// PRIVATE DNS ZONES
// ============================================================================

resource dnsCognitiveServices 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  tags: tags
}

resource dnsOpenAi 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
  tags: tags
}

resource dnsAiServices 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.services.ai.azure.com'
  location: 'global'
  tags: tags
}

// Link DNS zones to VNet
resource linkCognitiveServices 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsCognitiveServices
  name: 'link-cogservices'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource linkOpenAi 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsOpenAi
  name: 'link-openai'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource linkAiServices 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsAiServices
  name: 'link-aiservices'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output vnetId string = vnet.id
output snetApimId string = vnet.properties.subnets[0].id
output snetAcaId string = vnet.properties.subnets[1].id
output snetPeId string = vnet.properties.subnets[2].id
output dnsCognitiveServicesId string = dnsCognitiveServices.id
output dnsOpenAiId string = dnsOpenAi.id
output dnsAiServicesId string = dnsAiServices.id
