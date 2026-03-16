@description('Default domain of the internal Container Apps environment.')
param defaultDomain string

@description('Static IP of the internal Container Apps environment.')
param staticIp string

@description('VNet resource ID for DNS zone linking.')
param vnetId string

@description('Tags to apply to all resources.')
param tags object

// Private DNS zone matching the ACA environment's default domain
resource dnsAca 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: tags
}

resource dnsAcaLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsAca
  name: 'link-aca'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

// Wildcard A record pointing all *.defaultDomain to the environment's static IP
resource dnsAcaWildcard 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: dnsAca
  name: '*'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: staticIp
      }
    ]
  }
}
