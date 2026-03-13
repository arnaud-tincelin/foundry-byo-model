using './main.bicep'

// Set via: azd env set APIM_PUBLISHER_EMAIL you@example.com
param apimPublisherEmail = readEnvironmentVariable('APIM_PUBLISHER_EMAIL', 'admin@contoso.com')
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'production')
param location = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
