using './main.bicep'

// Customize these values before deploying.
// adminPassword is intentionally omitted here — pass it at deploy time
// to avoid storing credentials in source control.

param location      = 'centralus'
param adminUsername = 'azureuser'
