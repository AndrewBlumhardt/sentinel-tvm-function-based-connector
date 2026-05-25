targetScope = 'resourceGroup'

var datasetConfig = loadJsonContent('../Functions/datasets.json')
var datasets = datasetConfig.datasets
var scheduleDefaults = {
  // Daily ~01:00-02:45 UTC
  Schedule_DeviceTvmSoftwareInventory: '0 0 1 * * *'
  Schedule_DeviceTvmSoftwareVulnerabilities: '0 15 1 * * *'
  Schedule_DeviceTvmSoftwareVulnerabilitiesKB: '0 30 1 * * *'
  Schedule_DeviceTvmSecureConfigurationAssessment: '0 45 1 * * *'
  Schedule_DeviceTvmSecureConfigurationAssessmentKB: '0 0 2 * * *'
  Schedule_DeviceTvmInfoGathering: '0 15 2 * * *'
  Schedule_DeviceTvmSoftwareEvidenceBeta: '0 30 2 * * *'
  Schedule_DefApiSoftwareInventoryByMachine: '0 45 2 * * *'
  // Weekly Sun 03:00-06:15 UTC
  Schedule_DeviceTvmBrowserExtensions: '0 0 3 * * 0'
  Schedule_DeviceTvmBrowserExtensionsKB: '0 15 3 * * 0'
  Schedule_DeviceTvmCertificateInfo: '0 30 3 * * 0'
  Schedule_DeviceTvmHardwareFirmware: '0 45 3 * * 0'
  Schedule_DeviceTvmInfoGatheringKB: '0 0 4 * * 0'
  Schedule_DefApiBrowserExtensionPermissions: '0 15 4 * * 0'
  Schedule_DefApiBrowserExtensionsInventory: '0 30 4 * * 0'
  Schedule_DefApiCertificateInventoryAssessment: '0 45 4 * * 0'
  Schedule_DefApiHardwareFirmwareAssessment: '0 0 5 * * 0'
  Schedule_DefApiNonCpeSoftwareInventory: '0 15 5 * * 0'
  Schedule_DefApiRecommendations: '0 30 5 * * 0'
  Schedule_DefApiMachines: '0 45 5 * * 0'
  Schedule_DefApiSoftwareVulnerabilitiesByMachine: '0 0 6 * * 0'
  Schedule_DefApiSecureConfigAssessmentByMachine: '0 15 6 * * 0'
  // Every 10 days (1st, 11th, 21st) 07:00-08:00 UTC
  Schedule_DefApiVulnerabilitiesCatalog: '0 0 7 1,11,21 * *'
  Schedule_NistCveCatalog: '0 30 7 1,11,21 * *'
  Schedule_NistCpeConfigurations: '0 0 8 1,11,21 * *'
}
var locationName = empty(location) ? resourceGroup().location : location
var planName = '${namePrefix}-plan'
var dceName = empty(dataCollectionEndpointName) ? '${namePrefix}-dce' : dataCollectionEndpointName
var dcrName = empty(dataCollectionRuleName) ? '${namePrefix}-dcr' : dataCollectionRuleName
var appInsightsName = '${namePrefix}-appi'
var maxDataFlowsPerRule = 10
var dcrChunkCount = int((length(datasets) + maxDataFlowsPerRule - 1) / maxDataFlowsPerRule)
var dcrBatches = [for i in range(0, dcrChunkCount): take(skip(datasets, i * maxDataFlowsPerRule), maxDataFlowsPerRule)]
var scheduleAppSettings = [for dataset in datasets: {
  name: dataset.scheduleSetting
  value: scheduleDefaults[dataset.scheduleSetting] ?? '0 0 1 * * *'
}]
var commonAppSettings = [
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'python'
  }
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'AzureWebJobsFeatureFlags'
    value: 'EnableWorkerIndexing'
  }
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: '1'
  }
  {
    name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
    value: 'false'
  }
  {
    name: 'PYTHON_ISOLATE_WORKER_DEPENDENCIES'
    value: '1'
  }
  {
    name: 'DatasetConfigPath'
    value: 'Functions/datasets.json'
  }
  {
    name: 'CollectorVersion'
    value: string(datasetConfig.collectorVersion)
  }
  {
    name: 'LogsIngestion__Endpoint'
    value: dataCollectionEndpoint.properties.logsIngestion.endpoint
  }
  {
    name: 'Defender__HuntingBaseUrl'
    value: resolvedDefenderHuntingBaseUrl
  }
  {
    name: 'Defender__ApiBaseUrl'
    value: resolvedDefenderApiBaseUrl
  }
  {
    name: 'Defender__SecurityCenterApiBaseUrl'
    value: resolvedDefenderSecurityCenterApiBaseUrl
  }
  {
    name: 'ManagedIdentity__ClientId'
    value: ''
  }
  {
    name: 'Nist__ApiKey'
    value: ''
  }
]
// Per-dataset enable/disable is controlled in two places, NEITHER of which is an app setting:
//   1. datasets.json -> "enabled": true/false  (read by ConfigLoader, honored by DatasetRunner)
//   2. The Function App "Functions" blade in the portal -> per-function Enable/Disable toggle
// We intentionally do NOT emit Enabled_<DatasetName> app settings any more; nothing in the
// Python code reads them, and they only created portal clutter that conflicted with the
// real per-function enable switch operators actually use.
var mergedAppSettings = concat(commonAppSettings, scheduleAppSettings)

@description('Prefix used for generated resource names.')
param namePrefix string = 'sentinel-tvm'

@description('Azure region for the Function App, DCR, and DCE.')
param location string = resourceGroup().location

@description('Name of the Function App to create.')
param functionAppName string = '${namePrefix}-connector-func-${take(uniqueString(resourceGroup().id), 7)}'

@description('Name of the existing Log Analytics workspace used by Microsoft Sentinel.')
param workspaceName string

@description('Resource group containing the existing Log Analytics workspace.')
param workspaceResourceGroupName string = resourceGroup().name

@description('Name of the Data Collection Endpoint. Leave empty to use the default convention.')
param dataCollectionEndpointName string = ''

@description('Name of the Data Collection Rule. Leave empty to use the default convention.')
param dataCollectionRuleName string = ''

@description('Override for the Microsoft Defender API base URL. Leave empty to auto-select based on the deployment cloud: https://api.security.microsoft.com for Azure commercial, https://api-gov.security.microsoft.us for Azure Government. Set explicitly only when targeting a sovereign cloud the auto-mapping does not yet cover, or for testing.')
param defenderApiBaseUrl string = ''

@description('Override for the Microsoft Graph base URL used by Advanced Hunting (POST /v1.0/security/runHuntingQuery). Leave empty to auto-select: https://graph.microsoft.com on commercial, https://graph.microsoft.us on Azure Government.')
param defenderHuntingBaseUrl string = ''

@description('Override for the Defender for Endpoint (WindowsDefenderATP) REST API base URL used by GET /api/<Endpoint> calls. Leave empty to auto-select: https://api.security.microsoft.com on commercial, https://api-gov.securitycenter.microsoft.us on Azure Government (NOTE: this is a different host than Advanced Hunting on Gov).')
param defenderSecurityCenterApiBaseUrl string = ''

var autoDetectedDefenderApiBaseUrl = environment().name == 'AzureUSGovernment' ? 'https://api-gov.security.microsoft.us' : 'https://api.security.microsoft.com'
var resolvedDefenderApiBaseUrl = empty(defenderApiBaseUrl) ? autoDetectedDefenderApiBaseUrl : defenderApiBaseUrl
var autoDetectedDefenderHuntingBaseUrl = environment().name == 'AzureUSGovernment' ? 'https://graph.microsoft.us' : 'https://graph.microsoft.com'
var resolvedDefenderHuntingBaseUrl = empty(defenderHuntingBaseUrl) ? autoDetectedDefenderHuntingBaseUrl : defenderHuntingBaseUrl
var autoDetectedDefenderSecurityCenterApiBaseUrl = environment().name == 'AzureUSGovernment' ? 'https://api-gov.securitycenter.microsoft.us' : 'https://api.security.microsoft.com'
var resolvedDefenderSecurityCenterApiBaseUrl = empty(defenderSecurityCenterApiBaseUrl) ? autoDetectedDefenderSecurityCenterApiBaseUrl : defenderSecurityCenterApiBaseUrl

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  scope: resourceGroup(workspaceResourceGroupName)
  name: workspaceName
}

resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: appInsightsName
  location: locationName
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stg${uniqueString(resourceGroup().id, functionAppName)}'
  location: locationName
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: locationName
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: locationName
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

module workspaceTables './modules/workspaceTables.bicep' = {
  name: 'workspaceTables'
  scope: resourceGroup(workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    datasets: datasets
  }
}

resource dataCollectionRules 'Microsoft.Insights/dataCollectionRules@2023-03-11' = [for (datasetBatch, batchIndex) in dcrBatches: {
  name: '${dcrName}-${padLeft(string(batchIndex + 1), 2, '0')}'
  location: locationName
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: reduce(datasetBatch, {}, (state, dataset) => union(state, {
      '${dataset.dcrStreamName}': {
        columns: dataset.columns
      }
    }))
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'sentinelWorkspace'
        }
      ]
    }
    dataFlows: [for dataset in datasetBatch: {
      streams: [
        dataset.dcrStreamName
      ]
      destinations: [
        'sentinelWorkspace'
      ]
      outputStream: 'Custom-${dataset.destinationTable}'
      transformKql: 'source'
    }]
  }
  dependsOn: [
    workspaceTables
  ]
}]

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: locationName
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      // appSettings intentionally omitted here. All settings (runtime, storage, App Insights,
      // dataset toggles, schedules, and per-dataset DcrRuleId_*) are applied as a single
      // authoritative full-replace via the child Microsoft.Web/sites/config/appsettings
      // resource below. Splitting between siteConfig.appSettings and the child resource
      // causes the child resource (which is full-replace) to wipe anything not duplicated
      // in it -- including FUNCTIONS_WORKER_RUNTIME, FUNCTIONS_EXTENSION_VERSION,
      // AzureWebJobsStorage__*, and APPLICATIONINSIGHTS_CONNECTION_STRING, which prevents
      // the Function host from starting.
    }
  }
}
// Single authoritative app-settings resource. Microsoft.Web/sites/config/appsettings has
// FULL-REPLACE semantics, so this MUST contain every setting the Function App needs.
resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(
    toObject(mergedAppSettings, s => s.name, s => s.value),
    {
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
      AzureWebJobsStorage__accountName: storage.name
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__blobServiceUri: 'https://${storage.name}.blob.${environment().suffixes.storage}'
      AzureWebJobsStorage__queueServiceUri: 'https://${storage.name}.queue.${environment().suffixes.storage}'
      AzureWebJobsStorage__tableServiceUri: 'https://${storage.name}.table.${environment().suffixes.storage}'
      DcrRuleId_DeviceTvmSoftwareInventory: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmSoftwareVulnerabilities: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmSoftwareVulnerabilitiesKB: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmSecureConfigurationAssessment: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmSecureConfigurationAssessmentKB: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmSoftwareEvidenceBeta: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmBrowserExtensions: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmBrowserExtensionsKB: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmCertificateInfo: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmHardwareFirmware: dataCollectionRules[0].properties.immutableId
      DcrRuleId_DeviceTvmInfoGathering: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DeviceTvmInfoGatheringKB: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiSoftwareVulnerabilitiesByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiMachines: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiSoftwareInventoryByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiNonCpeSoftwareInventory: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiRecommendations: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiSecureConfigAssessmentByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiVulnerabilitiesCatalog: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiBrowserExtensionsInventory: dataCollectionRules[1].properties.immutableId
      DcrRuleId_DefApiBrowserExtensionPermissions: dataCollectionRules[2].properties.immutableId
      DcrRuleId_DefApiCertificateInventoryAssessment: dataCollectionRules[2].properties.immutableId
      DcrRuleId_DefApiHardwareFirmwareAssessment: dataCollectionRules[2].properties.immutableId
      DcrRuleId_NistCveCatalog: dataCollectionRules[2].properties.immutableId
      DcrRuleId_NistCpeConfigurations: dataCollectionRules[2].properties.immutableId
    }
  )
}

output functionAppName string = functionApp.name
output functionPrincipalId string = functionApp.identity.principalId
output storageAccountId string = storage.id
output dataCollectionEndpointResourceId string = dataCollectionEndpoint.id
output dataCollectionRuleImmutableId string = length(datasets) > 0 ? dataCollectionRules[0].properties.immutableId : ''
output dataCollectionRuleImmutableIds array = [for i in range(0, length(datasets) == 0 ? 0 : dcrChunkCount): dataCollectionRules[i].properties.immutableId]
output dataCollectionRuleResourceId string = length(datasets) > 0 ? dataCollectionRules[0].id : ''
output dataCollectionRuleResourceIds array = [for i in range(0, length(datasets) == 0 ? 0 : dcrChunkCount): dataCollectionRules[i].id]
output logsIngestionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output workspaceId string = workspace.id






