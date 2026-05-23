targetScope = 'resourceGroup'

var datasetConfig = loadJsonContent('../Functions/datasets.json')
var datasets = datasetConfig.datasets
var scheduleDefaults = {
  Schedule_DeviceTvmSoftwareInventory: '0 0,30 * * * *'
  Schedule_DeviceTvmSoftwareVulnerabilities: '0 0,30 * * * *'
  Schedule_DeviceTvmSoftwareVulnerabilitiesKB: '0 0,30 * * * *'
  Schedule_DeviceTvmSecureConfigurationAssessment: '0 0,30 * * * *'
  Schedule_DeviceTvmSecureConfigurationAssessmentKB: '0 0,30 * * * *'
  Schedule_DeviceTvmSoftwareEvidenceBeta: '0 0,30 * * * *'
  Schedule_DeviceTvmBrowserExtensions: '0 0,30 * * * *'
  Schedule_DeviceTvmBrowserExtensionsKB: '0 0,30 * * * *'
  Schedule_DeviceTvmCertificateInfo: '0 0,30 * * * *'
  Schedule_DeviceTvmHardwareFirmware: '0 0,30 * * * *'
  Schedule_DeviceTvmInfoGathering: '0 0,30 * * * *'
  Schedule_DeviceTvmInfoGatheringKB: '0 0,30 * * * *'
  Schedule_ApiSoftwareVulnerabilitiesByMachine: '0 0,30 * * * *'
  Schedule_ApiMachines: '0 0,30 * * * *'
  Schedule_ApiSoftwareInventoryByMachine: '0 0,30 * * * *'
  Schedule_ApiNonCpeSoftwareInventory: '0 0,30 * * * *'
  Schedule_ApiRecommendations: '0 0,30 * * * *'
  Schedule_ApiSecureConfigurationAssessmentByMachine: '0 0,30 * * * *'
  Schedule_ApiVulnerabilitiesCatalog: '0 0,30 * * * *'
  Schedule_ApiBrowserExtensionsInventory: '0 0,30 * * * *'
  Schedule_ApiBrowserExtensionPermissions: '0 0,30 * * * *'
  Schedule_ApiCertificateInventoryAssessment: '0 0,30 * * * *'
  Schedule_ApiHardwareFirmwareAssessment: '0 0,30 * * * *'
  Schedule_NistCveCatalog: '0 0,30 * * * *'
  Schedule_NistCpeConfigurations: '0 0,30 * * * *'
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
    name: 'Defender__ApiBaseUrl'
    value: resolvedDefenderApiBaseUrl
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
var datasetToggleSettings = [for dataset in datasets: {
  name: 'Enabled_${dataset.name}'
  value: string(bool(dataset.enabled))
}]


var mergedAppSettings = concat(commonAppSettings, datasetToggleSettings, scheduleAppSettings)

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

var autoDetectedDefenderApiBaseUrl = environment().name == 'AzureUSGovernment' ? 'https://api-gov.security.microsoft.us' : 'https://api.security.microsoft.com'
var resolvedDefenderApiBaseUrl = empty(defenderApiBaseUrl) ? autoDetectedDefenderApiBaseUrl : defenderApiBaseUrl

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
      DcrRuleId_ApiSoftwareVulnerabilitiesByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiMachines: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiSoftwareInventoryByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiNonCpeSoftwareInventory: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiRecommendations: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiSecureConfigurationAssessmentByMachine: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiVulnerabilitiesCatalog: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiBrowserExtensionsInventory: dataCollectionRules[1].properties.immutableId
      DcrRuleId_ApiBrowserExtensionPermissions: dataCollectionRules[2].properties.immutableId
      DcrRuleId_ApiCertificateInventoryAssessment: dataCollectionRules[2].properties.immutableId
      DcrRuleId_ApiHardwareFirmwareAssessment: dataCollectionRules[2].properties.immutableId
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






