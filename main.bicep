// ============================================================
// Minimal lab environment for testing Backup/Restore scripts
// Deploys: VNet, Azure Firewall Premium + Policy with sample rules
// Deploy time: ~5-10 minutes
// ============================================================

@description('Azure region for all resources.')
param location string = 'centralus'

// ============================================================
// VNet — single subnet for the firewall
// ============================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-fw-lab'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/24']
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: '10.0.0.0/26' }
      }
    ]
  }
}

// ============================================================
// Public IP for the firewall
// ============================================================

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-fw-lab'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ============================================================
// Firewall Policy (Premium) + Rule Collection Group
// ============================================================

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fw-policy-hub01'
  location: location
  properties: {
    sku: { tier: 'Premium' }
  }
}

resource firewallPolicyRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [

      // --------------------------------------------------------
      // Network Rules – priority 100
      // --------------------------------------------------------
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'NetworkRules'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            description: 'Allow DNS to Azure DNS resolver'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
            ipProtocols: ['UDP', 'TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            description: 'Allow NTP outbound'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['123']
            ipProtocols: ['UDP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Spoke-to-Spoke'
            description: 'Allow inter-spoke traffic via firewall'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-OnPrem-SSH'
            description: 'Allow SSH from onprem to spoke VMs'
            sourceAddresses: ['192.168.0.0/24']
            destinationAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationPorts: ['22']
            ipProtocols: ['TCP']
          }
        ]
      }

      // --------------------------------------------------------
      // Application Rules – priority 200
      // --------------------------------------------------------
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'ApplicationRules'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-WindowsUpdate'
            description: 'Allow Windows Update endpoints'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            fqdnTags: ['WindowsUpdate']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-MicrosoftServices'
            description: 'Allow Microsoft update and telemetry FQDNs'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: [
              '*.microsoft.com'
              '*.azure.com'
              '*.windowsazure.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-UbuntuAptRepos'
            description: 'Allow Ubuntu package manager repositories'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            targetFqdns: [
              '*.ubuntu.com'
              'security.ubuntu.com'
              'archive.ubuntu.com'
            ]
          }
        ]
      }
    ]
  }
}

// ============================================================
// Azure Firewall Premium
// ============================================================

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'fw-hub01'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Premium'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
  dependsOn: [firewallPolicyRules]
}

// ============================================================
// Outputs
// ============================================================

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallPublicIp string = firewallPip.properties.ipAddress
output policyName string = firewallPolicy.name
