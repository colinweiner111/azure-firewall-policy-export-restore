// ============================================================
// Minimal lab — VNet + Azure Firewall Premium with a realistic
// multi-RCG policy following the per-workload pattern described in:
// https://techcommunity.microsoft.com/blog/azurenetworksecurityblog/
//   organizing-rule-collections-and-rule-collection-groups-in-azure-firewall-policy/4138881
//
// Structure (Reference Implementation 1 — single policy, RCG per workload):
//   contosoWeb-rcg01       (500) — public-facing web app
//   contosoOps-rcg01       (600) — internal ops app (with internet deny)
//   contosoOps-test-rcg02  (700) — test/sandbox environment
//   platform-all-wrkls-rcg01 (800) — platform-wide rules (DNS, AD, Windows Update, web restrictions)
//
// Naming convention: <workload>-<type>-rc<n>  (matches article tables)
// Deploy time: ~5-10 minutes
// ============================================================

@description('Azure region for all resources.')
param location string = 'centralus'

// ── VNet ──────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-fw-lab'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/24'] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.0.0.0/26' } }
    ]
  }
}

// ── Public IP ─────────────────────────────────────────────────

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-fw-lab'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ── Firewall Policy (Premium) ─────────────────────────────────

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fw-policy-hub01'
  location: location
  properties: {
    sku: { tier: 'Premium' }
  }
}

// ── RCG 1: contosoWeb-rcg01 (priority 500) ───────────────────
// Public-facing web application (e-commerce / customer portal).
// Rule collections follow article ordering: DNAT → Network → Application.

resource rcgContosoWeb 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'contosoWeb-rcg01'
  properties: {
    priority: 500
    ruleCollections: [

      // DNAT first (priority 501) — required before network rules
      {
        ruleCollectionType: 'FirewallPolicyNatRuleCollection'
        name: 'contosoWeb-dnat-rc01'
        priority: 501
        action: { type: 'DNAT' }
        rules: [
          {
            ruleType: 'NatRule'
            name: 'DNAT-HTTPS-AppGateway'
            description: 'Forward inbound HTTPS to the Application Gateway VIP'
            sourceAddresses: ['*']
            destinationAddresses: [firewallPip.properties.ipAddress]
            destinationPorts: ['443']
            ipProtocols: ['TCP']
            translatedAddress: '10.10.1.4'
            translatedPort: '443'
          }
          {
            ruleType: 'NatRule'
            name: 'DNAT-HTTP-AppGateway'
            description: 'Forward inbound HTTP to AppGW — AppGW handles redirect to HTTPS'
            sourceAddresses: ['*']
            destinationAddresses: [firewallPip.properties.ipAddress]
            destinationPorts: ['80']
            ipProtocols: ['TCP']
            translatedAddress: '10.10.1.4'
            translatedPort: '80'
          }
        ]
      }

      // Network rules (priority 502)
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'contosoWeb-net-rc01'
        priority: 502
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AdminSSH-ContosoWeb'
            description: 'SSH from jump host subnet to ContosoWeb VMs'
            sourceAddresses: ['10.0.10.0/27']
            destinationAddresses: ['10.10.0.0/24']
            destinationPorts: ['22']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-App-to-SQL'
            description: 'App tier to Azure SQL / SQL Managed Instance'
            sourceAddresses: ['10.10.2.0/24']
            destinationAddresses: ['10.10.3.0/24']
            destinationPorts: ['1433']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-App-to-Redis'
            description: 'App tier to Redis Cache cluster'
            sourceAddresses: ['10.10.2.0/24']
            destinationAddresses: ['10.10.4.0/28']
            destinationPorts: ['6379', '6380']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-App-to-ServiceBus'
            description: 'App tier AMQP to Azure Service Bus (private endpoint)'
            sourceAddresses: ['10.10.2.0/24']
            destinationAddresses: ['ServiceBus']
            destinationPorts: ['5671', '5672', '443']
            ipProtocols: ['TCP']
          }
        ]
      }

      // Application rules last (priority 503)
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'contosoWeb-app-rc01'
        priority: 503
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-PaymentGateway'
            description: 'Payment processor APIs (Stripe, Braintree)'
            sourceAddresses: ['10.10.2.0/24']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'api.stripe.com'
              'api.braintreegateway.com'
              '*.braintree-api.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-CDN-Origins'
            description: 'CDN origin pulls and edge nodes'
            sourceAddresses: ['10.10.2.0/24']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              '*.azureedge.net'
              '*.akamaiedge.net'
              '*.cloudfront.net'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AppInsights'
            description: 'Application Insights telemetry and Live Metrics'
            sourceAddresses: ['10.10.2.0/24']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'dc.services.visualstudio.com'
              'live.applicationinsights.azure.com'
              '*.in.applicationinsights.azure.com'
              'rt.services.visualstudio.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AzureStorage'
            description: 'Azure Blob and Table Storage for app assets and state'
            sourceAddresses: ['10.10.2.0/24']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              '*.blob.${environment().suffixes.storage}'
              '*.table.${environment().suffixes.storage}'
              '*.queue.${environment().suffixes.storage}'
            ]
          }
        ]
      }
    ]
  }
}

// ── RCG 2: contosoOps-rcg01 (priority 600) ───────────────────
// Internal ops application (monitoring dashboards, ITSM, runbooks).
// No inbound from internet; internet outbound is explicitly denied.

resource rcgContosoOps 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'contosoOps-rcg01'
  dependsOn: [rcgContosoWeb]
  properties: {
    priority: 600
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'contosoOps-net-rc01'
        priority: 601
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Internal-Access-ContosoOps'
            description: 'Access to ContosoOps from Azure VNets and on-premises branches'
            sourceAddresses: ['10.0.0.0/8', '192.168.0.0/16']
            destinationAddresses: ['10.20.0.0/24']
            destinationPorts: ['443', '8443']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AdminSSH-ContosoOps'
            description: 'SSH from jump host to ContosoOps VMs'
            sourceAddresses: ['10.0.10.0/27']
            destinationAddresses: ['10.20.0.0/24']
            destinationPorts: ['22']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-MonitoringAgent-ContosoOps'
            description: 'Azure Monitor agent data upload from ContosoOps hosts'
            sourceAddresses: ['10.20.0.0/24']
            destinationAddresses: ['AzureMonitor']
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-ContosoOps-to-KeyVault'
            description: 'ContosoOps secret and certificate retrieval from Key Vault'
            sourceAddresses: ['10.20.0.0/24']
            destinationAddresses: ['AzureKeyVault']
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }

      // Explicit deny — internet access blocked for this internal workload
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'contosoOps-net-rc02'
        priority: 602
        action: { type: 'Deny' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Deny-ContosoOps-Internet'
            description: 'Block direct internet access from ContosoOps resources'
            sourceAddresses: ['10.20.0.0/24']
            destinationAddresses: ['*']
            destinationPorts: ['80', '443', '8080', '8443']
            ipProtocols: ['TCP']
          }
        ]
      }
    ]
  }
}

// ── RCG 3: contosoOps-test-rcg02 (priority 700) ──────────────
// Test / sandbox environment for ContosoOps.
// Isolated so test changes don't affect production rules.

resource rcgContosoOpsTest 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'contosoOps-test-rcg02'
  dependsOn: [rcgContosoOps]
  properties: {
    priority: 700
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'contosoOps-test-net-rc01'
        priority: 701
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Dev-Access-TestEnv'
            description: 'Developer access from jump host and on-prem dev workstations to ContosoOps test VMs'
            sourceAddresses: ['10.0.10.0/27', '192.168.10.0/24']
            destinationAddresses: ['10.20.10.0/24']
            destinationPorts: ['22', '3389', '443', '8443']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-TestEnv-to-SharedDB'
            description: 'Test environment access to shared dev/test SQL instance'
            sourceAddresses: ['10.20.10.0/24']
            destinationAddresses: ['10.0.20.0/28']
            destinationPorts: ['1433']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-TestEnv-Internet'
            description: 'Allow internet access from test environment (not allowed in prod)'
            sourceAddresses: ['10.20.10.0/24']
            destinationAddresses: ['*']
            destinationPorts: ['80', '443']
            ipProtocols: ['TCP']
          }
        ]
      }
    ]
  }
}

// ── RCG 4: platform-all-wrkls-rcg01 (priority 800) ───────────
// Workload-agnostic platform rules enforced by the central network team.
// Covers DNS, AD, patch management, and org-wide web restrictions.

resource rcgPlatform 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'platform-all-wrkls-rcg01'
  dependsOn: [rcgContosoOpsTest]
  properties: {
    priority: 800
    ruleCollections: [

      // Network rules (priority 801) — shared services and cloud platform
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'all-wrkls-net-rc01'
        priority: 801
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            description: 'DNS to Azure recursive resolver'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
            ipProtocols: ['UDP', 'TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            description: 'NTP time synchronization outbound'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['123']
            ipProtocols: ['UDP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-KMS'
            description: 'Windows KMS activation (Azure endpoint)'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['23.102.135.246']
            destinationPorts: ['1688']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AD-Authentication'
            description: 'Kerberos and LDAP to domain controllers'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['10.0.5.0/27']
            destinationPorts: ['88', '389', '636', '3268', '3269']
            ipProtocols: ['TCP', 'UDP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AD-Replication'
            description: 'AD replication RPC between domain controllers'
            sourceAddresses: ['10.0.5.0/27']
            destinationAddresses: ['10.0.5.0/27']
            destinationPorts: ['445', '49152-65535']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AzureMonitor'
            description: 'Azure Monitor and Log Analytics agent data upload'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['AzureMonitor']
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-GuestAndHybridManagement'
            description: 'Azure Arc agent and Guest Configuration extension'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['GuestAndHybridManagement']
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }

      // Application rules allow (priority 802) — Microsoft cloud services
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'all-wrkls-app-rc01'
        priority: 802
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-WindowsUpdate'
            description: 'Windows Update via FQDN tag (covers all required endpoints)'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            fqdnTags: ['WindowsUpdate']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Microsoft365'
            description: 'Microsoft 365 suite via FQDN tag'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            fqdnTags: ['Office365']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AzureManagement'
            description: 'Azure portal, ARM, and Entra ID authentication'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [{ protocolType: 'Https', port: 443 }]
            // These are intentional firewall rule targets, not ARM resource references.
            #disable-next-line no-hardcoded-env-urls
            targetFqdns: [
              'portal.azure.com'
              'management.azure.com'
              'login.microsoftonline.com'
              '*.login.microsoftonline.com'
              'graph.microsoft.com'
              'login.microsoft.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-MicrosoftDefender'
            description: 'Microsoft Defender for Endpoint sensor and cloud connectivity'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              '*.security.microsoft.com'
              'winatp-gw-cus.microsoft.com'
              'winatp-gw-eus.microsoft.com'
              '*.ods.opinsights.azure.com'
              '*.oms.opinsights.azure.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Ubuntu-Apt'
            description: 'Ubuntu package repositories for Linux VMs'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: [
              'archive.ubuntu.com'
              'security.ubuntu.com'
              '*.ubuntu.com'
              'packages.microsoft.com'
            ]
          }
        ]
      }

      // Application rules deny (priority 803) — org-wide web restrictions
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'all-wrkls-app-rc02'
        priority: 803
        action: { type: 'Deny' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Deny-Restricted-WebCategories'
            description: 'Block restricted web categories from all Azure networks per org policy'
            sourceAddresses: ['10.0.0.0/8']
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            webCategories: [
              'Gambling'
              'Violence'
              'Hacking'
              'IllegalSoftware'
            ]
          }
        ]
      }
    ]
  }
}

// ── Azure Firewall Premium ────────────────────────────────────

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
  dependsOn: [rcgPlatform]
}

// ── Outputs ───────────────────────────────────────────────────

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallPublicIp string = firewallPip.properties.ipAddress
output policyName string = firewallPolicy.name
