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

param apimPublisherEmail = 'admin@example.com'
param modelName = 'microsoft/Phi-4-mini-instruct'
param gpuWorkloadProfileType = 'NC24-A100'
