#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the minimal lab environment (VNet + Azure Firewall Premium + Policy).

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into. Created if it doesn't exist.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current az CLI subscription.

.PARAMETER Location
    Azure region for all resources. Default: centralus.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-fw-lab

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-fw-lab -Location eastus
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,
    [string]$Location = 'centralus'
)

if ($SubscriptionId) {
    Write-Host "Setting subscription to '$SubscriptionId'..." -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
}

$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Host "Deploying into subscription: $($sub.name) ($($sub.id))" -ForegroundColor Cyan

Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

Write-Host "Deploying Bicep template (Azure Firewall takes ~5-10 min)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file "$PSScriptRoot\main.bicep" `
    --parameters location=$Location `
    --name fw-lab-deploy

Write-Host "`nDeployment outputs:" -ForegroundColor Cyan
az deployment group show `
    --resource-group $ResourceGroupName `
    --name fw-lab-deploy `
    --query properties.outputs `
    --output table

Write-Host "`nLab ready. Run the backup script to take a snapshot:" -ForegroundColor Green
Write-Host "  .\Backup-FirewallPolicy.ps1 -ResourceGroupName $ResourceGroupName -PolicyName fw-policy-hub01" -ForegroundColor Yellow
