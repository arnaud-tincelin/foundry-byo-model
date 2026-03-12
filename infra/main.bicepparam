using './main.bicep'

// Minimal deployment parameters for Foundry BYO Model.
// Follows the AI-Landing-Zones "foundry-minimal-no-vnet" pattern.
//
// Usage:
//   azd up
// Or:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam

// Set via: azd env set APIM_PUBLISHER_EMAIL you@example.com
param apimPublisherEmail = readEnvironmentVariable('APIM_PUBLISHER_EMAIL', 'admin@contoso.com')
param modelName = 'microsoft/Phi-4-mini-instruct'
param gpuWorkloadProfileType = 'NC24-A100'
