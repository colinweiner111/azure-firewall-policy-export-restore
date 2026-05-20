#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the Azure Hub-Spoke topology using Bicep.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into. Created if it doesn't exist.

.PARAMETER SubscriptionId
    Azure subscription ID to deploy into. Defaults to the current az CLI subscription.

.PARAMETER Location
    Azure region for all resources. Default: centralus.

.PARAMETER AdminUsername
    VM administrator username. Default: azureuser.

.PARAMETER AdminPassword
    VM administrator password. Prompted securely if not supplied.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-hub-spoke-centralus01

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-hub-spoke-eastus01 -Location eastus

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-hub-spoke-centralus01 -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,
    [string]$Location      = 'centralus',
    [string]$AdminUsername = 'azureuser',

    [SecureString]$AdminPassword
)

# Switch subscription if specified
if ($SubscriptionId) {
    Write-Host "Setting subscription to '$SubscriptionId'..." -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
}

# Show which subscription we're deploying into
$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Host "Deploying into subscription: $($sub.name) ($($sub.id))" -ForegroundColor Cyan

if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Enter VM admin password' -AsSecureString
}

$plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
)

Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

Write-Host "Deploying Bicep template (VPN gateways take ~30 min)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file "$PSScriptRoot\main.bicep" `
    --parameters location=$Location adminUsername=$AdminUsername adminPassword=$plainPassword `
    --name hub-spoke-deploy

Write-Host "`nDeployment outputs:" -ForegroundColor Cyan
az deployment group show `
    --resource-group $ResourceGroupName `
    --name hub-spoke-deploy `
    --query properties.outputs `
    --output table
