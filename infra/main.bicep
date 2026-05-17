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
    name: 'LogsIngestion__RuleId'
    value: length(datasets) > 0 ? dataCollectionRules[0].properties.immutableId : ''
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
      appSettings: concat(mergedAppSettings, [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: 'https://${storage.name}.blob.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: 'https://${storage.name}.queue.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: 'https://${storage.name}.table.${environment().suffixes.storage}'
        }
      ])
    }
  }
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
